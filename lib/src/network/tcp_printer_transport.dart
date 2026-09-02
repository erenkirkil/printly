import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/connection_event.dart';
import '../core/connection_state.dart';
import '../core/printly_device.dart';
import '../core/printly_exception.dart';
import 'network_address.dart';

/// Opens a TCP [Socket]; injectable so tests can substitute a fake.
typedef SocketConnector =
    Future<Socket> Function(String host, int port, {Duration? timeout});

/// The TCP connect deadline is set this much *below* the caller's timeout so
/// a genuine network timeout surfaces as `connectTimeout` from here, ahead of
/// `ConnectionController`'s own guard timer. Losing that race would report the
/// controller's generic timeout instead of the transport's, hiding which layer
/// actually gave up.
const Duration kNetworkTimeoutHeadroom = Duration(milliseconds: 250);

/// Default deadline for a single [TcpPrinterTransport.write]. A `flush` that
/// does not complete within it means the printer stopped draining its socket
/// buffer — a jammed head, a dead link a half-open TCP connection still hides,
/// or a print server that accepted the connection and wandered off. None of
/// those recover by waiting, so the session is torn down rather than left
/// half-written; the caller reconnects and reprints the whole job.
const Duration kDefaultWriteTimeout = Duration(seconds: 30);

/// Pure-Dart TCP printer transport (raw ESC/POS over a socket, typically
/// port 9100). Owns one [Socket] per device and reports lifecycle changes on
/// [events] in the same shape the native transports use, so the connection
/// controller above it needs no network-specific branch.
///
/// That shape includes *where* an outcome is reported: [connect] and
/// [disconnect] never reject, they emit. Both native coordinators answer a
/// connect/disconnect request immediately and let `connectionEvents` carry
/// the terminal state, and `ConnectionController` is built on that contract —
/// it holds the caller's future open until an event arrives. A transport that
/// also threw would report the same failure twice, once ahead of its own
/// event. [write] is the exception, and matches native there too: its result
/// is the future, not an event.
class TcpPrinterTransport {
  /// Creates a transport. [connector] defaults to [Socket.connect]; tests
  /// inject a fake to drive timeouts and failures deterministically.
  TcpPrinterTransport({SocketConnector? connector})
    : _connector = connector ?? _defaultConnector;

  static Future<Socket> _defaultConnector(
    String host,
    int port, {
    Duration? timeout,
  }) => Socket.connect(host, port, timeout: timeout);

  final SocketConnector _connector;
  final Map<String, _TcpSession> _sessions = <String, _TcpSession>{};

  /// Per-key dial epoch, bumped by [disconnect] to cancel a dial that has not
  /// produced a socket yet. `connect` registers its session only *after* the
  /// await, so a mid-dial [disconnect] finds nothing in [_sessions]; without
  /// this counter the cancelled dial would still land, register and emit
  /// `connected` after the caller asked to stop.
  final Map<String, int> _dialEpochs = <String, int>{};

  /// How many dials for a key are currently awaiting a socket. Kept as a count
  /// (not a flag) because two concurrent `connect` calls for one device both
  /// dial, and the epoch entry may only be reclaimed once the last one lands.
  final Map<String, int> _dialsInFlight = <String, int>{};

  final StreamController<PrintlyConnectionEvent> _events =
      StreamController<PrintlyConnectionEvent>.broadcast();
  bool _disposed = false;

  /// Broadcast stream of connection lifecycle events for network devices.
  Stream<PrintlyConnectionEvent> get events => _events.stream;

  /// Opens a socket to [device] and reports the outcome on [events]:
  /// [ConnectionState.connected] once the socket is open,
  /// [ConnectionState.error] with the mapped wire reason when the dial fails,
  /// times out, or [PrintlyDevice.address] does not parse.
  ///
  /// The returned future completes either way and never rejects — the event
  /// is the single report, as it is on both native coordinators. Reporting a
  /// failure twice (an event *and* a rejection) would resolve the caller's
  /// attempt from the throw and leave the event trailing behind it, where it
  /// lands on the retry issued from the caller's catch block and rejects
  /// *that* attempt while its socket is already open.
  ///
  /// Idempotent: a second call for an already-open session re-emits
  /// `connected` without opening a new socket.
  ///
  /// A [disconnect] landing while the dial is still in flight cancels it: the
  /// socket that arrives late is destroyed and nothing is emitted, because
  /// `disconnect` already reported the terminal state.
  Future<void> connect(PrintlyDevice device, {Duration? timeout}) async {
    final String key = device.dedupKey;
    if (_sessions.containsKey(key)) {
      _emit(device, ConnectionState.connected);
      return;
    }

    final NetworkAddress addr;
    try {
      addr = NetworkAddress.parse(device.address);
    } on FormatException catch (e) {
      // Reason strings lead with the wire code and append the detail: the
      // controller resolves an unrecognised reason to `connectFailed`, so the
      // caller still gets the right `PrintlyErrorCode` and keeps the detail
      // that says which address failed to parse.
      _emit(
        device,
        ConnectionState.error,
        failureReason:
            '${PrintlyErrorCode.connectFailed.wireName}: '
            'invalid network address "${device.address}" (${e.message})',
      );
      return;
    }

    final Duration? deadline = timeout == null ? null : _dialBack(timeout);
    // Two deadlines, deliberately staggered. `dart:io` reports its own connect
    // timeout as a SocketException (never a TimeoutException), and an injected
    // connector may ignore the argument outright — so the classification that
    // reaches the caller has to come from the guard below, and the connector
    // gets a strictly later budget purely as a backstop that aborts the dial
    // and frees the descriptor. Same-duration deadlines would race and report
    // connectFailed or connectTimeout for the same stalled printer.
    final Future<Socket> pending = _connector(
      addr.host,
      addr.port,
      timeout: deadline == null ? null : deadline + kNetworkTimeoutHeadroom,
    );
    // Registered after the call, not before: a connector body runs
    // synchronously up to its first suspension, so no `disconnect` can
    // interleave in between, and a connector that throws synchronously never
    // leaves a phantom dial behind.
    final int epoch = _dialEpochs[key] ?? 0;
    _dialsInFlight[key] = (_dialsInFlight[key] ?? 0) + 1;

    try {
      final Socket socket = deadline == null
          ? await pending
          : await pending.timeout(deadline);
      // A dispose, a cancelling disconnect or a racing connect may have landed
      // while we awaited. In every case this socket is unwanted and must be
      // destroyed here — nothing else holds a reference to it.
      if (_disposed || _cancelled(key, epoch) || _sessions.containsKey(key)) {
        socket.destroy();
        return;
      }
      final _TcpSession session = _TcpSession(socket);
      _sessions[key] = session;
      // Watch for remote close / socket error → one disconnected event.
      session.subscription = socket.listen(
        (_) {},
        onError: (Object _, StackTrace _) => _handleDrop(device, session),
        onDone: () => _handleDrop(device, session),
        cancelOnError: true,
      );
      _emit(device, ConnectionState.connected);
    } on SocketException catch (e) {
      // A cancelled dial has already been reported as `disconnected`; turning
      // its failure into a second, contradictory terminal event would resolve
      // the caller's next attempt against a stale outcome.
      if (_cancelled(key, epoch)) return;
      _emit(
        device,
        ConnectionState.error,
        failureReason:
            '${PrintlyErrorCode.connectFailed.wireName}: '
            '${e.message} (${addr.canonical})'
            '${Platform.isAndroid ? ' — declare android.permission.INTERNET' : ''}',
      );
      return;
    } on TimeoutException {
      // The dial may still succeed after we gave up: close whatever arrives
      // so the descriptor does not leak, and absorb a late error so it cannot
      // resurface as an unhandled asynchronous error.
      unawaited(
        pending.then<void>(
          (Socket socket) => socket.destroy(),
          onError: (Object _, StackTrace _) {},
        ),
      );
      if (_cancelled(key, epoch)) return;
      _emit(
        device,
        ConnectionState.error,
        failureReason: PrintlyErrorCode.connectTimeout.wireName,
      );
      return;
    } finally {
      _releaseDial(key);
    }
  }

  /// Closes the socket to [device] and emits [ConnectionState.disconnected].
  ///
  /// Also cancels a dial that is still in flight, so "connect, then change my
  /// mind" cannot resolve as a live connection a moment later.
  ///
  /// The event is emitted even when there is nothing to close, which is what
  /// both native coordinators do for a session they do not have
  /// (`ConnectionCoordinator.kt`, `ConnectionCoordinator.swift` — Android's
  /// comment spells out the reason: the UI must not wedge in
  /// "disconnecting"). `ConnectionController` emits `disconnecting`
  /// locally and then waits for this event, so staying silent would strand
  /// the device in `disconnecting` forever — reached by simply disconnecting
  /// after a failed connect, where the caller has an error state to clear and
  /// this transport has no session.
  Future<void> disconnect(PrintlyDevice device) async {
    final String key = device.dedupKey;
    if (_dialsInFlight.containsKey(key)) {
      _dialEpochs[key] = (_dialEpochs[key] ?? 0) + 1;
    }
    final _TcpSession? session = _sessions.remove(key);
    if (session != null) _closeSession(session);
    _emit(device, ConnectionState.disconnected);
  }

  /// Writes [bytes] to the open socket for [device] and completes once the
  /// socket buffer is flushed.
  ///
  /// Completion means "handed to the OS", not "printed": TCP/9100 is a one-way
  /// pipe with no acknowledgement, so this is the strongest guarantee the
  /// transport can offer. It is still a real guarantee — a session torn down
  /// before the flush finished rejects rather than completing, so success
  /// never covers a job the socket dropped. Rejects with
  /// [PrintlyWriteException]:
  /// [PrintlyErrorCode.notConnected] (no open session),
  /// [PrintlyErrorCode.writeBusy] (a write is already in flight),
  /// [PrintlyErrorCode.writeTimeout] (flush exceeded [writeTimeout] — the
  /// session is then torn down), [PrintlyErrorCode.disconnected] (socket
  /// closed mid-write), or [PrintlyErrorCode.writeFailed] (other failure).
  ///
  /// Writes are serialised per device rather than queued: two overlapping jobs
  /// would interleave their bytes on the wire and print one garbled receipt,
  /// so the second caller is rejected and can retry on a known-clean session.
  Future<void> write(
    PrintlyDevice device,
    Uint8List bytes, {
    Duration writeTimeout = kDefaultWriteTimeout,
  }) async {
    final _TcpSession? session = _sessions[device.dedupKey];
    if (session == null) {
      throw const PrintlyWriteException(
        PrintlyErrorCode.notConnected,
        'no open network connection for this device',
      );
    }
    if (session.writing) {
      throw const PrintlyWriteException(
        PrintlyErrorCode.writeBusy,
        'a previous write is still in flight',
      );
    }
    session.writing = true;
    try {
      session.socket.add(bytes);
      await session.socket.flush().timeout(writeTimeout);
    } on TimeoutException {
      // The bytes already queued cannot be recalled, so the socket is not
      // reusable: a later job would resume mid-receipt. Tear it down.
      _handleDrop(device, session);
      throw const PrintlyWriteException(
        PrintlyErrorCode.writeTimeout,
        'printer stopped acknowledging the write',
      );
    } on SocketException catch (e) {
      // Socket died under us. Drop the session so the next write reports
      // notConnected instead of writing into a corpse.
      _handleDrop(device, session);
      throw PrintlyWriteException(
        PrintlyErrorCode.disconnected,
        'connection dropped during write: ${e.message}',
      );
    } catch (e) {
      throw PrintlyWriteException(
        PrintlyErrorCode.writeFailed,
        'write failed: $e',
      );
    } finally {
      session.writing = false;
    }

    // A completed `flush()` is not proof the job left the machine: `dart:io`
    // resolves a pending flush *normally* when the socket is destroyed under
    // it, so every graceful teardown — a peer FIN, a concurrent `disconnect`,
    // a `dispose` — would be reported as a printed receipt while most of the
    // bytes were discarded. Only an abortive reset raises the SocketException
    // the branch above catches, which would leave the outcome depending on
    // whether the printer sent RST or FIN; the graceful case is the common one
    // (idle timeout, paper-out, a print server cycling). Deliberately outside
    // the `try`: thrown inside it, the generic `catch` would remap this to
    // `writeFailed` and lose the reason the caller needs to decide on a retry.
    if (session.closedLocally || _sessions[device.dedupKey] != session) {
      throw const PrintlyWriteException(
        PrintlyErrorCode.disconnected,
        'connection closed before the job was fully flushed',
      );
    }
  }

  /// Closes every open socket and the event stream. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final _TcpSession session in _sessions.values) {
      _closeSession(session);
    }
    _sessions.clear();
    await _events.close();
  }

  /// Subtracts [kNetworkTimeoutHeadroom] from [timeout], but never below a
  /// usable value: a caller passing a timeout at or under the headroom would
  /// otherwise get a zero-or-negative deadline, i.e. an instant timeout with
  /// no dial attempted at all. Such a caller keeps their own budget instead.
  static Duration _dialBack(Duration timeout) {
    final Duration reduced = timeout - kNetworkTimeoutHeadroom;
    return reduced > Duration.zero ? reduced : timeout;
  }

  bool _cancelled(String key, int epoch) => (_dialEpochs[key] ?? 0) != epoch;

  void _releaseDial(String key) {
    final int remaining = (_dialsInFlight[key] ?? 1) - 1;
    if (remaining > 0) {
      _dialsInFlight[key] = remaining;
      return;
    }
    // Last dial for this key landed: nothing can observe the epoch any more,
    // so drop both entries instead of growing a map per device seen.
    _dialsInFlight.remove(key);
    _dialEpochs.remove(key);
  }

  /// Releases the OS resources behind [session]. Cancelling the read
  /// subscription is not enough on its own — an un-destroyed socket keeps its
  /// file descriptor (a peer-closed one sits in CLOSE_WAIT forever), and a POS
  /// app that reconnects per receipt would walk into the process fd limit.
  void _closeSession(_TcpSession session) {
    session.closedLocally = true;
    final StreamSubscription<Uint8List>? subscription = session.subscription;
    session.subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    session.socket.destroy();
  }

  /// Single teardown path for a session that ended without the caller asking:
  /// a remote close, a socket error, or a [write] that timed out. Identity is
  /// checked rather than just the key, so a stale session can never evict its
  /// replacement or report a state the live one contradicts.
  void _handleDrop(PrintlyDevice device, _TcpSession session) {
    // Ignore the drop of a session we already closed (local disconnect or
    // dispose) — prevents a double disconnected event.
    if (session.closedLocally) return;
    final String key = device.dedupKey;
    // A session no longer in the map is orphaned; still close it, but only the
    // live one gets to report the device's state.
    final bool current = _sessions[key] == session;
    if (current) _sessions.remove(key);
    _closeSession(session);
    if (current) _emit(device, ConnectionState.disconnected);
  }

  void _emit(
    PrintlyDevice device,
    ConnectionState state, {
    String? failureReason,
  }) {
    if (_events.isClosed) return;
    _events.add(
      PrintlyConnectionEvent(
        device: device,
        state: state,
        failureReason: failureReason,
      ),
    );
  }
}

/// One open socket, its read subscription, and the flag that tells a
/// remote-close handler whether the close was initiated locally (so it does
/// not emit a second event).
class _TcpSession {
  _TcpSession(this.socket);

  final Socket socket;

  /// Assigned immediately after [socket] is listened to; cleared on teardown.
  /// Held so the close path can cancel it — dropping the reference alone
  /// leaves the read side subscribed to a socket nobody owns.
  StreamSubscription<Uint8List>? subscription;

  bool closedLocally = false;

  /// True between the start of a [TcpPrinterTransport.write] and its
  /// completion. Guards the socket against interleaved jobs — ESC/POS is a
  /// byte stream with no framing, so two concurrent writes print one receipt
  /// woven out of both.
  bool writing = false;
}

import 'dart:async';
import 'dart:io' show Platform;

import 'package:rxdart/rxdart.dart';

import '../core/connection_event.dart';
import '../core/connection_state.dart';
import '../core/connection_type.dart';
import '../core/printly_device.dart';
import '../core/printly_exception.dart';
import '../platform/printly_platform_interface.dart';

/// Default timeout handed to [ConnectionController.connect] when the caller
/// does not provide one. Classic RFCOMM typically takes ~1–3 s; BLE GATT
/// can take longer on the first attempt while bonding completes.
const Duration kDefaultConnectTimeout = Duration(seconds: 10);

/// Owns the per-device connection lifecycle and exposes broadcast streams
/// for consumers.
///
/// The controller serialises native work so duplicate taps or rapid
/// connect/disconnect cycles never produce overlapping native calls:
///
/// * Concurrent [connect] calls for the same device share the same in-flight
///   future — no second native request is issued.
/// * [connect] for a new device while another is open first disconnects the
///   current one and then attempts the new one (queued, not parallel).
/// * [disconnect] while nothing is connected is a no-op.
///
/// Connection lifecycle events from the native side fan out into
/// [connectionStateOf] streams and a single [activeDeviceStream] observing
/// whichever device is currently connected.
class ConnectionController {
  /// Creates a controller that delegates native work to [platform].
  ConnectionController({PrintlyPlatform? platform})
    : _platform = platform ?? PrintlyPlatform.instance {
    _eventsSubscription = _platform.connectionEvents.listen(
      _onConnectionEvent,
      onError: _onConnectionEventError,
    );
  }

  final PrintlyPlatform _platform;

  final Map<String, BehaviorSubject<ConnectionState>> _states =
      <String, BehaviorSubject<ConnectionState>>{};
  final Map<String, PrintlyDevice> _knownDevices = <String, PrintlyDevice>{};
  final Map<String, String?> _lastFailureReasons = <String, String?>{};
  final Map<String, ConnectionType> _transports = <String, ConnectionType>{};
  final Map<String, _PendingConnect> _pendingConnects =
      <String, _PendingConnect>{};
  final Map<String, Future<void>> _pendingDisconnects =
      <String, Future<void>>{};

  final BehaviorSubject<PrintlyDevice?> _activeDeviceSubject =
      BehaviorSubject<PrintlyDevice?>.seeded(null);

  StreamSubscription<PrintlyConnectionEvent>? _eventsSubscription;
  bool _disposed = false;

  /// Broadcast stream of the currently-connected device, or `null` when no
  /// link is open. Useful for wiring a "connected to: …" UI banner.
  Stream<PrintlyDevice?> get activeDeviceStream => _activeDeviceSubject.stream;

  /// Synchronous snapshot of [activeDeviceStream].
  PrintlyDevice? get activeDevice => _activeDeviceSubject.value;

  /// Per-device broadcast stream of state transitions. Always seeded with
  /// the last known state (defaults to [ConnectionState.disconnected] for
  /// devices the controller has not observed yet), so late subscribers
  /// immediately receive the current state.
  Stream<ConnectionState> connectionStateOf(PrintlyDevice device) =>
      _subjectFor(device).stream;

  /// Synchronous snapshot of [connectionStateOf] for [device].
  ConnectionState stateOf(PrintlyDevice device) =>
      _states[device.dedupKey]?.value ?? ConnectionState.disconnected;

  /// Most recent failure reason reported for [device], if any. Cleared on
  /// the next successful connect.
  String? lastFailureReasonOf(PrintlyDevice device) =>
      _lastFailureReasons[device.dedupKey];

  /// The transport [connect] chose (or was told to use) for [device]: the
  /// active link's transport, or the last one used if [device] is currently
  /// disconnected. `null` if [device] has never been connected through this
  /// controller.
  ConnectionType? transportOf(PrintlyDevice device) =>
      _transports[device.dedupKey];

  /// Resolves which [ConnectionType] a [connect] call for [device] should
  /// use. Pure and side-effect free, so it is independently testable.
  ///
  /// Rule, in order:
  /// * [explicit] != `null` → use it, but only if it is one of
  ///   [PrintlyDevice.availableTransports]; otherwise [ArgumentError].
  /// * [PrintlyDevice.availableTransports] contains [ConnectionType.network]
  ///   → [ConnectionType.network]. (In practice the facade's `connect()`
  ///   fails fast with `PrintlyUnsupportedException(networkNotSupported)`
  ///   before this function is ever reached for a network device, since that
  ///   transport is not implemented yet — this branch exists so the pure
  ///   rule stays total.)
  /// * [isIOS] → [ConnectionType.ble] if available; otherwise
  ///   [PrintlyUnsupportedException] with
  ///   [PrintlyErrorCode.classicRequiresMfi] — iOS cannot open Bluetooth
  ///   Classic links without MFi certification, so a Classic-only device has
  ///   no usable transport on iOS.
  /// * Otherwise (Android) → [ConnectionType.classic] if available (the
  ///   field-proven, most reliable RFCOMM path for dual-mode radios),
  ///   otherwise [ConnectionType.ble].
  static ConnectionType resolveTransport(
    PrintlyDevice device, {
    required bool isIOS,
    ConnectionType? explicit,
  }) {
    if (explicit != null) {
      if (!device.availableTransports.contains(explicit)) {
        throw ArgumentError.value(
          explicit,
          'explicit',
          'not in device.availableTransports '
              '(${device.availableTransports})',
        );
      }
      return explicit;
    }
    if (device.availableTransports.contains(ConnectionType.network)) {
      return ConnectionType.network;
    }
    if (isIOS) {
      if (device.availableTransports.contains(ConnectionType.ble)) {
        return ConnectionType.ble;
      }
      throw const PrintlyUnsupportedException(
        PrintlyErrorCode.classicRequiresMfi,
        'iOS cannot open Bluetooth Classic links without MFi certification; '
        'connect over BLE instead.',
      );
    }
    if (device.availableTransports.contains(ConnectionType.classic)) {
      return ConnectionType.classic;
    }
    return ConnectionType.ble;
  }

  /// Opens a link to [device].
  ///
  /// The returned future resolves only when the native side reports a terminal
  /// [ConnectionState] for [device] — it completes on
  /// [ConnectionState.connected] and completes with an error on
  /// [ConnectionState.error]/[ConnectionState.disconnected] or when [timeout]
  /// elapses. So `await connect()` genuinely means "connected", not merely
  /// "the request was dispatched".
  ///
  /// [transport] picks which [ConnectionType] to use for a dual-mode radio;
  /// see [resolveTransport] for the selection rule when it is omitted. The
  /// chosen value is remembered ([transportOf]) and reused for the matching
  /// [disconnect] and write calls — the native side keys a session by
  /// `type:address`, so those calls must agree with the transport [connect]
  /// actually used.
  ///
  /// * If already connected to [device] and [transport] is omitted or
  ///   matches the active link's transport → returns immediately (the
  ///   caller's intent, "be connected to this printer", is already met).
  /// * If already connected to [device] over a *different* transport than
  ///   the explicit [transport] requested (e.g. linked over Classic, caller
  ///   now asks for BLE on the same dual-mode radio) → disconnects the old
  ///   link first, then opens a fresh one over [transport]. A cross-transport
  ///   switch always requires an explicit [transport]; omitting it never
  ///   triggers a switch.
  /// * If a connect attempt is in flight for [device] → returns the same
  ///   future (re-entrancy safe), so duplicate taps never start a second
  ///   native attempt.
  /// * If a different device is currently connected → disconnects it first,
  ///   then connects to [device] (serialised).
  Future<void> connect(
    PrintlyDevice device, {
    ConnectionType? transport,
    Duration timeout = kDefaultConnectTimeout,
  }) {
    _assertNotDisposed();
    final String key = device.dedupKey;

    final _PendingConnect? pending = _pendingConnects[key];
    if (pending != null) return pending.completer.future;

    if (stateOf(device) == ConnectionState.connected) {
      final ConnectionType? active = _transports[key];
      if (transport == null || active == transport) {
        return Future<void>.value();
      }
      return _switchTransportThenConnect(device, transport, timeout);
    }

    final ConnectionType chosen;
    try {
      chosen = resolveTransport(
        device,
        isIOS: Platform.isIOS,
        explicit: transport,
      );
    } catch (error, stackTrace) {
      return Future<void>.error(error, stackTrace);
    }
    _transports[key] = chosen;

    final Completer<void> completer = Completer<void>();
    final Timer timer = Timer(timeout, () {
      _lastFailureReasons[key] = PrintlyErrorCode.connectTimeout.wireName;
      _emitLocal(device, ConnectionState.error);
      _resolvePendingConnect(key, PrintlyConnectionTimeoutException(timeout));
    });
    // `disconnect(); connect(device);` without awaiting: the old link's
    // terminal `disconnected` event is still on its way and must not be
    // mistaken for this fresh attempt failing.
    final bool teardownInFlight =
        _pendingDisconnects.containsKey(key) ||
        stateOf(device) == ConnectionState.disconnecting;
    _pendingConnects[key] = _PendingConnect(
      completer,
      timer,
      ignoreNextDisconnect: teardownInFlight,
    );
    unawaited(_startConnect(device, chosen, timeout));
    return completer.future;
  }

  /// Cross-transport switch: tears down the link currently open over the
  /// previously-chosen transport, then issues a fresh [connect] pinned to
  /// [transport]. Used only from [connect] when the caller explicitly asks
  /// for a transport that differs from the active one.
  Future<void> _switchTransportThenConnect(
    PrintlyDevice device,
    ConnectionType transport,
    Duration timeout,
  ) async {
    await disconnect(device: device);
    await connect(device, transport: transport, timeout: timeout);
  }

  Future<void> _startConnect(
    PrintlyDevice device,
    ConnectionType transport,
    Duration timeout,
  ) async {
    final String key = device.dedupKey;
    try {
      final PrintlyDevice? previous = activeDevice;
      if (previous != null && previous.dedupKey != key) {
        await _safeDisconnect(previous);
      }
      _knownDevices[key] = device;
      _lastFailureReasons[key] = null;
      _emitLocal(device, ConnectionState.connecting);
      // The native call returns as soon as the request is dispatched; the real
      // outcome arrives asynchronously via [connectionEvents] and resolves the
      // pending connect in [_onConnectionEvent] (or the timeout above fires).
      await _platform.connect(
        device: device,
        transport: transport,
        timeout: timeout,
      );
    } catch (error) {
      _lastFailureReasons[key] = error.toString();
      _emitLocal(device, ConnectionState.error);
      _resolvePendingConnect(key, error);
    }
  }

  void _resolvePendingConnect(String key, Object? error) {
    final _PendingConnect? pending = _pendingConnects.remove(key);
    if (pending == null) return;
    pending.timer.cancel();
    if (pending.completer.isCompleted) return;
    if (error == null) {
      pending.completer.complete();
    } else {
      pending.completer.completeError(error);
    }
  }

  /// Closes the current link. When [device] is omitted, disconnects the
  /// currently active device (if any).
  ///
  /// * No-op when the target is already disconnected.
  /// * Re-entrancy safe: concurrent calls share a single pending future.
  Future<void> disconnect({PrintlyDevice? device}) {
    _assertNotDisposed();
    final PrintlyDevice? target = device ?? activeDevice;
    if (target == null) return Future<void>.value();

    final String key = target.dedupKey;
    final Future<void>? pending = _pendingDisconnects[key];
    if (pending != null) return pending;

    final ConnectionState current = stateOf(target);
    if (current == ConnectionState.disconnected) {
      return Future<void>.value();
    }

    final Future<void> future = _runDisconnect(target);
    _pendingDisconnects[key] = future;
    return future;
  }

  Future<void> _runDisconnect(PrintlyDevice device) async {
    final String key = device.dedupKey;
    // Reuse the transport [connect] chose for this session — the native
    // side keys the session by `type:address`, so disconnecting with a
    // different transport would silently miss it. Falls back to resolving
    // fresh only for the defensive case of a disconnect with no prior
    // recorded connect (state must already be non-disconnected to reach
    // here, so this should not normally trigger).
    final ConnectionType transport =
        _transports[key] ?? resolveTransport(device, isIOS: Platform.isIOS);
    try {
      _emitLocal(device, ConnectionState.disconnecting);
      await _platform.disconnect(device: device, transport: transport);
    } finally {
      unawaited(_pendingDisconnects.remove(key));
    }
  }

  /// Disconnects without throwing — used when [connect] needs to switch away
  /// from a previous device. A failure to gracefully close is acceptable
  /// because the new connect attempt is about to replace the link anyway.
  Future<void> _safeDisconnect(PrintlyDevice device) async {
    try {
      await disconnect(device: device);
    } catch (_) {
      /* best-effort */
    }
  }

  void _onConnectionEvent(PrintlyConnectionEvent event) {
    if (_disposed) return;
    final String key = event.device.dedupKey;

    // Terminal event of the *previous* link during a disconnect-then-connect
    // sequence: swallow it entirely so it neither rejects the fresh connect
    // nor flips the public state away from `connecting`.
    final _PendingConnect? pendingForKey = _pendingConnects[key];
    if (event.state == ConnectionState.disconnected &&
        pendingForKey != null &&
        pendingForKey.ignoreNextDisconnect) {
      pendingForKey.ignoreNextDisconnect = false;
      return;
    }

    _knownDevices[key] = event.device;
    if (event.state == ConnectionState.error) {
      _lastFailureReasons[key] = event.failureReason;
    } else if (event.state == ConnectionState.connected) {
      _lastFailureReasons[key] = null;
    }
    _emitLocal(event.device, event.state);

    // Resolve an in-flight connect() when the native side reaches a terminal
    // state (a no-op when nothing is pending for this device).
    switch (event.state) {
      case ConnectionState.connected:
        _resolvePendingConnect(key, null);
      case ConnectionState.error:
        final PrintlyErrorCode code = PrintlyErrorCode.fromWireName(
          event.failureReason,
        );
        _resolvePendingConnect(
          key,
          PrintlyConnectionException(
            code == PrintlyErrorCode.unknown
                ? PrintlyErrorCode.connectFailed
                : code,
            event.failureReason ?? PrintlyErrorCode.connectFailed.wireName,
          ),
        );
      case ConnectionState.disconnected:
        _resolvePendingConnect(
          key,
          const PrintlyConnectionException(
            PrintlyErrorCode.disconnected,
            'disconnected before connect completed',
          ),
        );
      case ConnectionState.connecting:
      case ConnectionState.disconnecting:
      case ConnectionState.reconnecting:
        break;
    }
  }

  void _onConnectionEventError(Object error, StackTrace stack) {
    /* Swallow — native will emit an error event when the state actually
       changes. No global invalidation needed. */
  }

  void _emitLocal(PrintlyDevice device, ConnectionState state) {
    _subjectFor(device).add(state);
    _updateActiveDevice(device, state);
  }

  void _updateActiveDevice(PrintlyDevice device, ConnectionState state) {
    final PrintlyDevice? current = _activeDeviceSubject.value;
    if (state == ConnectionState.connected) {
      if (current?.dedupKey != device.dedupKey) {
        _activeDeviceSubject.add(device);
      }
      return;
    }
    if (current?.dedupKey == device.dedupKey &&
        state != ConnectionState.connecting &&
        state != ConnectionState.reconnecting) {
      _activeDeviceSubject.add(null);
    }
  }

  BehaviorSubject<ConnectionState> _subjectFor(PrintlyDevice device) {
    return _states.putIfAbsent(
      device.dedupKey,
      () =>
          BehaviorSubject<ConnectionState>.seeded(ConnectionState.disconnected),
    );
  }

  void _assertNotDisposed() {
    if (_disposed) {
      throw StateError('ConnectionController used after dispose()');
    }
  }

  /// Releases subscriptions and subjects. Called from tests; the production
  /// singleton lives for the process lifetime.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _eventsSubscription?.cancel();
    _eventsSubscription = null;
    for (final _PendingConnect pending in _pendingConnects.values) {
      pending.timer.cancel();
    }
    _pendingConnects.clear();
    await _activeDeviceSubject.close();
    for (final BehaviorSubject<ConnectionState> subject in _states.values) {
      await subject.close();
    }
    _states.clear();
    _pendingDisconnects.clear();
  }
}

/// A connect attempt awaiting its terminal [ConnectionState], guarded by a
/// [timer] that fails the attempt if the native side never reports back.
class _PendingConnect {
  _PendingConnect(
    this.completer,
    this.timer, {
    this.ignoreNextDisconnect = false,
  });

  final Completer<void> completer;
  final Timer timer;

  /// Set when the attempt was started while the same device was still
  /// tearing down: the next `disconnected` event belongs to the old link
  /// and is ignored once.
  bool ignoreNextDisconnect;
}

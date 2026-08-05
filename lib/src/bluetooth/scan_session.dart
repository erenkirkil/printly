import 'dart:async';

import 'package:rxdart/rxdart.dart';

import '../core/connection_type.dart';
import '../core/printly_device.dart';
import 'scan_controller.dart';

/// Screen-scoped scanning handle. Obtain one from
/// `Printly.instance.newScanSession()` — never constructed directly.
///
/// ## Why this exists (three field bugs)
///
/// [ScanController.devicesStream] and [ScanController.isScanningStream] are
/// process-lifetime [BehaviorSubject]s: correct for a singleton that outlives
/// any one screen, but they replay their last value to every *new*
/// subscriber — including a screen that just mounted and has never scanned
/// anything itself. Three separate consumer bugs traced back to exactly that
/// replay landing in a fresh screen's `initState`:
///
/// 1. A stale `isScanning: false` (left over from a previous visit's
///    finished scan) replayed into a screen that had just optimistically
///    flipped its own "scanning…" UI on, and immediately overwrote it back
///    to idle.
/// 2. A replay reading as "scan just finished, zero devices found" was
///    indistinguishable from a genuine empty result and triggered a phantom
///    BLE-fallback code path in consumer code — the list was actually two
///    minutes old, not fresh.
/// 3. A device list accumulated over an old scan (42 devices, some long out
///    of range) rendered on screen *before* the new visit's own scan had
///    even started; a tap on one of the stale entries then tried to connect
///    to a printer that had moved out of range, and died on the connect
///    timeout.
///
/// A [PrintlyScanSession] fixes all three by seeding [devices]/[isScanning]
/// empty/`false` and only forwarding [ScanController] events discovered
/// *after* its own [start] is called — see [start]'s doc for exactly how.
///
/// ## Ref-counted stop
///
/// Multiple sessions can be active (e.g. two screens both scanning). The
/// native scan is a single shared resource owned by [ScanController], so
/// [stop] only reaches the platform once every other active session has
/// also stopped — see [stop].
class PrintlyScanSession {
  PrintlyScanSession._({
    required ScanController controller,
    required Duration Function() resolveDefaultTimeout,
  }) : _controller = controller,
       _resolveDefaultTimeout = resolveDefaultTimeout;

  final ScanController _controller;
  final Duration Function() _resolveDefaultTimeout;

  /// Module-level ref-count registry of every session currently holding a
  /// live subscription to [_controller]. [start] adds `this`; [stop] (and
  /// [dispose], which behaves like [stop] first when active) remove it.
  /// [stop] only calls [ScanController.stopScan] once this set is empty —
  /// i.e. once the last screen still watching has let go.
  static final Set<PrintlyScanSession> _active = <PrintlyScanSession>{};

  final BehaviorSubject<List<PrintlyDevice>> _devicesSubject =
      BehaviorSubject<List<PrintlyDevice>>.seeded(const <PrintlyDevice>[]);
  final BehaviorSubject<bool> _isScanningSubject = BehaviorSubject<bool>.seeded(
    false,
  );

  StreamSubscription<List<PrintlyDevice>>? _devicesSub;
  StreamSubscription<bool>? _isScanningSub;

  /// Whether this session currently holds a live subscription to
  /// [_controller] (i.e. [start] has run and neither [stop] nor [dispose]
  /// has released it since). Distinct from [_disposed]: a session can
  /// [stop], then [start] again.
  bool _running = false;
  bool _disposed = false;

  /// Broadcast stream of discovered devices, seeded empty. Never replays a
  /// previous visit's list — see the class doc.
  Stream<List<PrintlyDevice>> get devices => _devicesSubject.stream;

  /// Broadcast stream of this session's own scanning state, seeded `false`.
  /// Only mirrors [ScanController.isScanningStream] transitions that happen
  /// while this session is running (between [start] and [stop]/[dispose]) —
  /// see the class doc.
  Stream<bool> get isScanning => _isScanningSubject.stream;

  /// Synchronous snapshot of [devices].
  List<PrintlyDevice> get currentDevices => _devicesSubject.value;

  /// Starts (or joins) a scan through the shared [ScanController].
  ///
  /// [timeout] defaults to whatever the resolver passed at construction
  /// returns — in production that is `Printly.instance.defaultScanTimeout`,
  /// resolved lazily so a value changed after this session was created (but
  /// before [start] is called) still applies. [types], [includeBonded] and
  /// [strategy] are forwarded verbatim to [ScanController.startScan].
  ///
  /// ### The replay-skip mechanism
  ///
  /// The first time [start] runs (or the first time after a [stop]), this
  /// method subscribes to [ScanController.devicesStream] and
  /// [ScanController.isScanningStream] with `.skip(1)`, then — with **no
  /// `await` in between** — calls [ScanController.startScan].
  ///
  /// That ordering, not just the `.skip(1)`, is what makes the skip target
  /// exactly the stale replay and nothing else: both streams are seeded
  /// [BehaviorSubject]s, and rxdart delivers a fresh subscriber's replay
  /// value asynchronously (scheduled at `.listen()` time, not emitted
  /// synchronously inside the `.listen()` call — this mirrors how
  /// `ScanController`'s own emission tests need `Future.delayed(Duration.zero)`
  /// before observing the seeded value). Dart is single-threaded and
  /// nothing between two statements with no `await` can run on the event
  /// loop, so the replay's scheduled delivery is guaranteed to be queued
  /// *before* anything [ScanController.startScan] itself adds (its own
  /// synchronous prefix — clearing dedup, resetting the device list —  runs
  /// immediately after, in the same synchronous turn). `.skip(1)` therefore
  /// always drops precisely the pre-`start()` replay, never a discovery that
  /// is genuinely fresh. Reordering these two calls, or inserting an
  /// `await` between them, would reopen the exact race this class exists to
  /// close.
  Future<void> start({
    Duration? timeout,
    Set<ConnectionType>? types,
    bool includeBonded = true,
    ScanStrategy strategy = ScanStrategy.parallel,
  }) async {
    _assertNotDisposed();
    if (!_running) {
      _devicesSub = _controller.devicesStream.skip(1).listen((
        List<PrintlyDevice> value,
      ) {
        if (!_disposed) _devicesSubject.add(value);
      });
      _isScanningSub = _controller.isScanningStream.skip(1).listen((
        bool value,
      ) {
        if (!_disposed) _isScanningSubject.add(value);
      });
      _active.add(this);
      _running = true;
    }
    await _controller.startScan(
      timeout: timeout ?? _resolveDefaultTimeout(),
      types: types,
      includeBonded: includeBonded,
      strategy: strategy,
    );
  }

  /// Releases this session's hold on the shared scan. Safe to call when not
  /// running (no-op, mirrors [ScanController.stopScan]'s own no-op-when-idle
  /// contract).
  ///
  /// Always cancels this session's own subscriptions to [_controller]
  /// immediately — from this point [devices]/[isScanning] stop moving even
  /// if another session keeps the native scan alive. Only calls
  /// [ScanController.stopScan] once [_active] is empty, i.e. once every
  /// other session sharing the native scan has also stopped.
  Future<void> stop() async {
    _assertNotDisposed();
    await _release();
  }

  /// Idempotent. If this session is still running, behaves like [stop]
  /// first (releasing its subscriptions and ref-count share), then closes
  /// this session's own subjects. Calling [start] afterwards throws
  /// [StateError].
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _release();
    await _devicesSubject.close();
    await _isScanningSubject.close();
  }

  Future<void> _release() async {
    if (!_running) return;
    _running = false;
    await _devicesSub?.cancel();
    _devicesSub = null;
    await _isScanningSub?.cancel();
    _isScanningSub = null;
    _active.remove(this);
    if (_active.isEmpty) {
      await _controller.stopScan();
    }
  }

  void _assertNotDisposed() {
    if (_disposed) {
      throw StateError('PrintlyScanSession used after dispose()');
    }
  }
}

/// Internal factory bridging [PrintlyScanSession]'s otherwise
/// library-private constructor across files: [PrintlyScanSession._] can
/// only be called from within this file, so `Printly.newScanSession()` (a
/// different file) goes through this function instead. Deliberately **not**
/// exported by the public barrel (`lib/printly.dart` exports only the
/// `PrintlyScanSession` type) — `Printly.instance.newScanSession()` is the
/// only supported way for SDK consumers to obtain a session. Tests that need
/// a session bound to a fake platform (bypassing the process-wide facade
/// singleton) import this file directly, the same way
/// `test/bluetooth/scan_controller_test.dart` imports
/// `scan_controller.dart` directly instead of going through the barrel.
PrintlyScanSession createScanSession({
  required ScanController controller,
  required Duration Function() resolveDefaultTimeout,
}) => PrintlyScanSession._(
  controller: controller,
  resolveDefaultTimeout: resolveDefaultTimeout,
);

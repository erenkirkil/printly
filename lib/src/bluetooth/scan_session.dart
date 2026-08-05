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
/// empty/`false` and only reacting to [ScanController] state that is honestly
/// current as of this session's own [start] — see [start]'s doc for exactly
/// how, including what "current" means when [start] joins a scan that was
/// already running.
///
/// ## The guarantee, precisely
///
/// A session never observes state from a scan that ended *before* its
/// [start]. Joining a scan already in flight is different from replaying a
/// finished one: it forwards that live scan's current finds (and `true` for
/// [isScanning]) as an honest snapshot, not stale data — the scan is still
/// running, so what it has found so far is still current.
///
/// ## Ref-counted stop
///
/// Multiple sessions can be active (e.g. two screens both scanning). The
/// native scan is a single shared resource owned by [ScanController], so
/// [stop] only reaches the platform once every other active session sharing
/// the same [ScanSessionRegistry] has also stopped — see [stop].
///
/// ## Interaction with the global scan API
///
/// Sessions and `Printly.instance`'s own `startScan`/`stopScan` share one
/// native scan through the same [ScanController] — there is no separate
/// "session scan" at the platform level. `Printly.instance.stopScan()` ends
/// the native scan outright, which also ends it for every active session
/// (their [isScanning] observes `false` just like a session-initiated stop);
/// conversely, the last session's [stop] ends a scan even if it was
/// originally started through the global `Printly.instance.startScan()`
/// rather than through a session.
class PrintlyScanSession {
  PrintlyScanSession._({
    required ScanController controller,
    required ScanSessionRegistry registry,
    required Duration Function() resolveDefaultTimeout,
  }) : _controller = controller,
       _registry = registry,
       _resolveDefaultTimeout = resolveDefaultTimeout;

  final ScanController _controller;
  final ScanSessionRegistry _registry;
  final Duration Function() _resolveDefaultTimeout;

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

  /// The arm gate: while `false`, the forwarding listeners registered in
  /// [start] early-return instead of pushing into this session's own
  /// subjects. Set `true` only after `_controller.startScan()` has
  /// completed — see [start]'s doc for why this is what replaces `.skip(1)`.
  bool _armed = false;
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
  /// before [start] is called) still applies.
  ///
  /// **On join, `timeout`/`types`/`includeBonded`/`strategy` are IGNORED.**
  /// If a scan is already running when [start] is called, [start] joins it
  /// rather than starting a second one — [ScanController.startScan] itself
  /// no-ops when a scan is already in flight, so whatever parameters the
  /// *original* caller passed are the ones that govern; this session's own
  /// arguments are silently discarded for that call.
  ///
  /// ### Arm-after-start
  ///
  /// The first time [start] runs (or the first time after a [stop]), this
  /// method subscribes to [ScanController.devicesStream] and
  /// [ScanController.isScanningStream] immediately, but with an `_armed`
  /// gate closed: the forwarding listeners early-return without touching
  /// this session's own subjects until the gate opens. Only then does it
  /// `await _controller.startScan(...)`.
  ///
  /// This replaces an earlier `.skip(1)`-based scheme that dropped exactly
  /// one emission per stream on the assumption that the *next* emission
  /// after subscribing was always the seeded replay. That assumption broke
  /// on two paths:
  ///
  /// - **Start behind a pending stop.** If a [stop] (or a concurrent
  ///   `Printly.instance.stopScan()`) was still in flight, `.skip(1)` would
  ///   swallow the replay, but [ScanController]'s own stop-completion
  ///   emission — the *full stale list* from before this session existed —
  ///   would land right after, un-skipped.
  /// - **Joining an in-flight scan.** [ScanController.startScan] no-ops
  ///   when a scan is already running, so no fresh `[]` reset is ever
  ///   emitted for `.skip(1)` to *not* skip — the session would sit
  ///   silently behind the stale replay it *did* skip, and
  ///   [isScanningStream] would never tell it the scan is actually running.
  ///
  /// Arm-after-start closes both. While unarmed, the gate drops every
  /// emission — the pending-stop's stale full-list emission included, since
  /// it lands before this session is armed. Once
  /// `await _controller.startScan(...)` completes, one of two states holds:
  /// either a fresh scan started (`ScanController._runStart` ran, so the
  /// list is `[]`), or this session joined a scan that was already live
  /// (the list is that scan's genuinely current finds — not stale, since it
  /// was accumulated during a window that is *still open*). At that point
  /// the gate opens (`_armed = true`) and a synchronous snapshot of
  /// [ScanController.currentDevices] / [ScanController.isScanning] is
  /// pushed into this session's own subjects (skipped when it would just
  /// repeat the value already held, to avoid a duplicate seed emission).
  /// Every controller emission after that point forwards normally.
  ///
  /// Reordering the subscribe/arm/await sequence, or opening the gate
  /// before `startScan()` resolves, would reopen the exact races this
  /// method exists to close.
  Future<void> start({
    Duration? timeout,
    Set<ConnectionType>? types,
    bool includeBonded = true,
    ScanStrategy strategy = ScanStrategy.parallel,
  }) async {
    _assertNotDisposed();
    if (!_running) {
      _armed = false;
      _devicesSub = _controller.devicesStream.listen((
        List<PrintlyDevice> value,
      ) {
        if (!_armed || _disposed) return;
        _devicesSubject.add(value);
      });
      _isScanningSub = _controller.isScanningStream.listen((bool value) {
        if (!_armed || _disposed) return;
        _isScanningSubject.add(value);
      });
      _registry.add(this);
      _running = true;
    }
    await _controller.startScan(
      timeout: timeout ?? _resolveDefaultTimeout(),
      types: types,
      includeBonded: includeBonded,
      strategy: strategy,
    );
    _armed = true;
    if (_disposed) return;
    final List<PrintlyDevice> devicesSnapshot = _controller.currentDevices;
    if (!_sameDevices(devicesSnapshot, _devicesSubject.value)) {
      _devicesSubject.add(devicesSnapshot);
    }
    final bool isScanningSnapshot = _controller.isScanning;
    if (isScanningSnapshot != _isScanningSubject.value) {
      _isScanningSubject.add(isScanningSnapshot);
    }
  }

  /// Releases this session's hold on the shared scan. Safe to call when not
  /// running, and safe to call after [dispose] — both are silent no-ops
  /// (mirrors [ScanController.stopScan]'s own no-op-when-idle contract).
  ///
  /// Always cancels this session's own subscriptions to [_controller]
  /// immediately — from this point [devices]/[isScanning] stop moving even
  /// if another session keeps the native scan alive. Only calls
  /// [ScanController.stopScan] once this session's [ScanSessionRegistry] is
  /// empty, i.e. once every other session sharing it has also stopped.
  Future<void> stop() async {
    if (_disposed) return;
    await _release();
  }

  /// Idempotent. If this session is still running, behaves like [stop]
  /// first (releasing its subscriptions and registry share), then closes
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
    _armed = false;
    await _devicesSub?.cancel();
    _devicesSub = null;
    await _isScanningSub?.cancel();
    _isScanningSub = null;
    _registry.remove(this);
    // Reset this session's own list so a stop→start cycle (or a subscriber
    // that joins after this stop) never sees this run's leftover list —
    // the same stale-replay hazard [start] guards against, self-inflicted.
    if (!_disposed) {
      _devicesSubject.add(const <PrintlyDevice>[]);
    }
    if (_registry.isEmpty) {
      await _controller.stopScan();
    }
  }

  void _assertNotDisposed() {
    if (_disposed) {
      throw StateError('PrintlyScanSession used after dispose()');
    }
  }

  static bool _sameDevices(List<PrintlyDevice> a, List<PrintlyDevice> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Instance-owned registry of active [PrintlyScanSession]s.
///
/// Replaces a process-wide static set: a static registry meant every
/// session ever created anywhere in the process (including across unrelated
/// tests, each with their own fake [ScanController]) shared one ref-count,
/// and a session that was never disposed kept a strong reference alive for
/// the lifetime of the process. `Printly` creates exactly one
/// [ScanSessionRegistry] alongside its [ScanController] and threads it
/// through every session it hands out via [createScanSession], so ref-count
/// scope matches [ScanController] scope: one native scan, one registry,
/// tracking only the sessions actually sharing that scan.
///
/// Not exported by the public barrel — `PrintlyScanSession` is the only
/// public type from this file (see `lib/printly.dart`'s `show` clause);
/// this registry is an implementation detail passed internally from
/// `Printly` to [createScanSession].
class ScanSessionRegistry {
  final Set<PrintlyScanSession> _active = <PrintlyScanSession>{};

  /// Whether no session is currently holding a live subscription. [stop]/
  /// [dispose] on the last remaining session is what flips this back to
  /// `true`, at which point they call through to [ScanController.stopScan].
  bool get isEmpty => _active.isEmpty;

  /// Registers [session] as holding a live subscription. Called from
  /// [PrintlyScanSession.start] the first time it runs (or the first time
  /// after a [PrintlyScanSession.stop]).
  void add(PrintlyScanSession session) => _active.add(session);

  /// Unregisters [session]. Called from [PrintlyScanSession.stop]/
  /// [PrintlyScanSession.dispose] via `_release()`; a no-op if [session]
  /// was not registered (mirrors [Set.remove]'s own idempotence).
  void remove(PrintlyScanSession session) => _active.remove(session);
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
///
/// [registry] must be the same [ScanSessionRegistry] instance shared by
/// every other session that should ref-count against [controller]'s native
/// scan together — see [ScanSessionRegistry]'s doc for why this is no
/// longer a module-level static.
PrintlyScanSession createScanSession({
  required ScanController controller,
  required ScanSessionRegistry registry,
  required Duration Function() resolveDefaultTimeout,
}) => PrintlyScanSession._(
  controller: controller,
  registry: registry,
  resolveDefaultTimeout: resolveDefaultTimeout,
);

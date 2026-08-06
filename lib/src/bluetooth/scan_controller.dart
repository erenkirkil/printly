import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart' show PlatformException;
import 'package:rxdart/rxdart.dart';

import '../core/connection_type.dart';
import '../core/printly_device.dart';
import '../core/printly_exception.dart';
import '../platform/printly_platform_interface.dart';

/// Default timeout for [ScanController.startScan] when the caller does not
/// provide one. A powered, in-range thermal printer answers within the
/// first few seconds; the remaining window only harvests anonymous ambient
/// BLE advertisers and keeps the radio busy — measured in the field at
/// ~100 devices in 30 s.
const Duration kDefaultScanTimeout = Duration(seconds: 10);

/// Default set of transports to scan when the caller passes no explicit
/// preference. Network scanning is intentionally excluded — network printers
/// are added directly via [PrintlyDevice.network].
const Set<ConnectionType> kDefaultScanTypes = <ConnectionType>{
  ConnectionType.classic,
  ConnectionType.ble,
};

/// How often the deduplicated device list is (at most) re-emitted while a scan
/// is running. BLE advertisements arrive many times per second per device
/// (each RSSI update is a fresh callback); emitting a new list for every one
/// floods the UI with rebuilds. Coalescing to this interval collapses a burst
/// into a single update, which is the difference between a smooth list and a
/// janky one on a device-dense floor.
const Duration kScanEmitInterval = Duration(milliseconds: 250);

/// Execution strategy for [ScanController.startScan].
enum ScanStrategy {
  /// Requests every configured transport in a single native scan. This is
  /// the strategy [ScanController] used before [classicFirst] existed, and
  /// remains the default.
  parallel,

  /// Android-only two-round strategy encoding a pattern observed in the
  /// field: a Bluetooth Classic inquiry saturates the 2.4 GHz radio,
  /// starving a concurrent BLE scan of airtime. Scanning Classic first and
  /// only falling back to BLE once nothing answered finds printers a
  /// parallel scan can miss under radio contention — this is how the
  /// reference kentkart app located the PTP-II.
  ///
  /// Round 1 requests `{ConnectionType.classic}` only, for the resolved
  /// timeout. When that window elapses, [ScanController.currentDevices] is
  /// checked for a device with [PrintlyDevice.hasName] and
  /// [PrintlyDevice.seenInScan] both `true` (a bonded-cache seed that was
  /// never actually confirmed by an inquiry does not count, see
  /// [PrintlyDevice.seenInScan]):
  /// - If one is present, a real printer already answered Classic and the
  ///   scan stops normally — a BLE round would only add radio contention
  ///   for no benefit.
  /// - Otherwise the native scan is stopped and restarted with
  ///   `{ConnectionType.ble}` for the *same* timeout duration. The device
  ///   list accumulated in round 1 is preserved, not cleared, and
  ///   [ScanController.isScanningStream] never emits `false` during the
  ///   transition — from the caller's point of view this reads as one
  ///   continuous scan, not two.
  ///
  /// There is never a third round (loop protection): whatever round 2
  /// finds — or doesn't — the strategy ends there. Alternating
  /// Classic/BLE indefinitely on an empty result would just spin the radio
  /// forever for a printer that genuinely isn't in range.
  ///
  /// Ignored on iOS, which has no public Bluetooth Classic API — there,
  /// `classicFirst` degrades silently to a single `{ConnectionType.ble}`
  /// round (equivalent to [parallel] with `types: {ConnectionType.ble}`).
  ///
  /// Types precedence: when [ScanController.startScan]'s `types` argument
  /// is supplied together with this strategy, the strategy governs and
  /// `types` is ignored for round composition (round 1 is always
  /// `{classic}`, round 2 always `{ble}`). Letting an explicit transport
  /// set override a strategy that already dictates transports per round
  /// would be an ambiguous contract; the simplest honest one is that the
  /// strategy decides.
  classicFirst,
}

/// Owns the discovery lifecycle and exposes deduplicated device lists.
///
/// The controller is re-entrancy safe by design: concurrent calls to
/// [startScan] share a single native scan and receive the same in-flight
/// future, and [stopScan] is a no-op when no scan is running. This is the
/// behaviour [Printly.instance] relies on when UI code can fire duplicate
/// button taps.
class ScanController {
  /// Creates a controller that delegates native work to [platform]. Tests
  /// pass a fake platform; production code uses [PrintlyPlatform.instance].
  ///
  /// [emitInterval] bounds how often [devicesStream] re-emits during a scan
  /// (see [kScanEmitInterval]); tests pass [Duration.zero] for immediacy.
  ScanController({
    PrintlyPlatform? platform,
    Duration emitInterval = kScanEmitInterval,
  }) : _platform = platform ?? PrintlyPlatform.instance,
       _emitInterval = emitInterval {
    _resultsSubscription = _platform.scanResults.listen(
      _onDeviceDiscovered,
      onError: _onScanError,
    );
  }

  final PrintlyPlatform _platform;
  final Duration _emitInterval;

  final BehaviorSubject<List<PrintlyDevice>> _devicesSubject =
      BehaviorSubject<List<PrintlyDevice>>.seeded(const <PrintlyDevice>[]);
  final BehaviorSubject<bool> _isScanningSubject = BehaviorSubject<bool>.seeded(
    false,
  );
  final PublishSubject<PrintlyException> _scanErrorsSubject =
      PublishSubject<PrintlyException>();

  final Map<String, PrintlyDevice> _dedup = <String, PrintlyDevice>{};

  StreamSubscription<PrintlyDevice>? _resultsSubscription;
  Timer? _timeoutTimer;
  Timer? _emitTimer;
  Future<void>? _pendingStart;
  Future<void>? _pendingStop;
  bool _disposed = false;
  bool _includeBonded = true;
  bool _includeUnnamed = false;

  /// Whether the in-progress scan is running the Android two-round
  /// [ScanStrategy.classicFirst] transition (i.e. `strategy` was
  /// `classicFirst` *and* the platform is not iOS — see [ScanStrategy]).
  bool _classicFirstActive = false;

  /// Whether round 2 (the BLE fallback round) has already been started —
  /// this is the loop-protection flag: once `true`,
  /// [_onScanWindowElapsed] never starts another round.
  bool _fallbackRoundDone = false;

  /// The timeout each classicFirst round runs for; round 2 reuses the same
  /// duration round 1 was given.
  Duration? _activeTimeout;

  /// Broadcast stream of the currently known devices, deduplicated and
  /// emitted as an immutable list on each change.
  ///
  /// Three things to know before wiring this into UI:
  /// - The list replays for the lifetime of the controller — it never
  ///   forgets a device on its own between scans. Call [clearDevices] before
  ///   a fresh scan if stale entries from a previous session/location would
  ///   be misleading.
  /// - Treat [isScanningStream] as the transition signal, not this stream: a
  ///   device can still be added or updated for a moment after scanning
  ///   stops (the final coalesced flush in [stopScan]).
  /// - A Classic bonded-cache seed ([PrintlyDevice.seenInScan] `false`) can
  ///   be out of range or long powered off — its presence here only means it
  ///   is paired at the OS level, not that it is reachable right now.
  ///
  /// Screen-scoped consumers (a subscription that starts and ends with one
  /// screen) should prefer `Printly.instance.newScanSession()` instead —
  /// this stream's replay-to-every-subscriber behaviour is right for the
  /// process-wide singleton but leaks a previous screen's stale state into
  /// a fresh one.
  Stream<List<PrintlyDevice>> get devicesStream => _devicesSubject.stream;

  /// Broadcast stream signalling whether a native scan is in progress.
  Stream<bool> get isScanningStream => _isScanningSubject.stream;

  /// Broadcast stream of asynchronous scan failures.
  ///
  /// [startScan]'s future only reflects errors thrown at dispatch time; a
  /// scan that dies mid-flight (Bluetooth toggled off, native scan-failed
  /// callbacks) would otherwise look identical to a normal timeout stop.
  /// Each such failure is surfaced here as a typed [PrintlyException] right
  /// before [isScanningStream] flips to `false`.
  Stream<PrintlyException> get scanErrors => _scanErrorsSubject.stream;

  /// Synchronous snapshot of the current device list — handy for state
  /// management integrations that want an initial value without subscribing.
  /// Read from the live dedup map, not the last stream emission: RSSI-only
  /// refreshes deliberately do not re-emit on [devicesStream] (see
  /// [_flushEmit]), so the subject's value can lag on signal strength. This
  /// snapshot never does.
  List<PrintlyDevice> get currentDevices =>
      List<PrintlyDevice>.unmodifiable(_dedup.values);

  /// Synchronous snapshot of [isScanningStream].
  bool get isScanning => _isScanningSubject.value;

  /// Starts a native scan and returns a future that completes once the scan
  /// has been requested from the platform. The scan auto-stops after
  /// [timeout] has elapsed; call [stopScan] to end earlier.
  ///
  /// Calling [startScan] while a scan is already running is a no-op and
  /// returns the in-flight future, so duplicate button taps can never start
  /// parallel native scans or leak timers. Calling it while a [stopScan] is
  /// still in flight queues the start behind the pending stop (the natural
  /// "rescan" gesture), instead of silently dropping it.
  ///
  /// [timeout] defaults to [kDefaultScanTimeout] when omitted. [types]
  /// defaults to [defaultScanTypesForPlatform] for the running platform
  /// (iOS never requests Classic — it has no public Classic API). When
  /// [includeBonded] is `false`, Classic bonded-cache seeds
  /// ([PrintlyDevice.seenInScan] `false`) are dropped instead of being
  /// added to [devicesStream]; a seed later confirmed by an actual inquiry
  /// result still appears once [PrintlyDevice.mergeWith] flips
  /// [PrintlyDevice.seenInScan] to `true`.
  ///
  /// When [includeUnnamed] is `false` (the default) nameless BLE
  /// advertisements are excluded — natively where possible (so they never
  /// cross the platform channel) and again here as defense in depth.
  /// Measured in the field, 135 of 141 records in one office scan were
  /// nameless privacy-rotated phones, wearables and beacons; a thermal
  /// printer must advertise its name to be pickable, so the default hides
  /// what no consumer can present as a choice. Pass `true` to see
  /// everything (diagnostic UIs, or pairing flows that identify a device by
  /// address). Nameless *Classic* sightings are never dropped: Android's
  /// inquiry can deliver the name in a later follow-up broadcast, and the
  /// record completes via [PrintlyDevice.mergeWith].
  ///
  /// [strategy] defaults to [ScanStrategy.parallel] (the historical
  /// behaviour: [types] requested in one native scan). See
  /// [ScanStrategy.classicFirst] for the Android Classic-then-BLE fallback
  /// strategy, including why an explicit [types] is ignored when [strategy]
  /// is [ScanStrategy.classicFirst].
  Future<void> startScan({
    Duration? timeout,
    Set<ConnectionType>? types,
    bool includeBonded = true,
    bool includeUnnamed = false,
    ScanStrategy strategy = ScanStrategy.parallel,
  }) {
    _assertNotDisposed();
    final Duration effectiveTimeout = timeout ?? kDefaultScanTimeout;
    final Set<ConnectionType> effectiveTypes =
        types ?? defaultScanTypesForPlatform(isIOS: Platform.isIOS);
    if (_pendingStart != null) return _pendingStart!;

    final Future<void>? stopping = _pendingStop;
    if (stopping != null) {
      // `stopScan(); startScan();` without awaiting: isScanning is still true
      // until the stop resolves, so the old `if (isScanning)` short-circuit
      // would swallow the restart. Chain it behind the stop instead; a failed
      // stop still lets the start proceed.
      _pendingStart = stopping
          .then<void>((_) {}, onError: (_) {})
          .then(
            (_) => _runStart(
              timeout: effectiveTimeout,
              types: effectiveTypes,
              includeBonded: includeBonded,
              includeUnnamed: includeUnnamed,
              strategy: strategy,
            ),
          );
      return _pendingStart!;
    }
    if (isScanning) return Future<void>.value();

    _pendingStart = _runStart(
      timeout: effectiveTimeout,
      types: effectiveTypes,
      includeBonded: includeBonded,
      includeUnnamed: includeUnnamed,
      strategy: strategy,
    );
    return _pendingStart!;
  }

  /// Platform-aware default transport set for [startScan] when the caller
  /// passes no explicit [startScan.types]. Separated as a pure, static
  /// function (rather than reading `Platform.isIOS` inline) so it is
  /// testable without a platform channel or device.
  ///
  /// iOS is BLE-only here because it has no public Bluetooth Classic API —
  /// requesting Classic there would either be ignored or fail outright, so
  /// asking for it by default is never useful. Android gets both: Classic
  /// SPP/RFCOMM printers remain common in the field alongside BLE ones.
  static Set<ConnectionType> defaultScanTypesForPlatform({
    required bool isIOS,
  }) => isIOS ? const <ConnectionType>{ConnectionType.ble} : kDefaultScanTypes;

  /// Round-1 transport set for [ScanStrategy.classicFirst], factored out as
  /// a pure, static function for the same testability reason as
  /// [defaultScanTypesForPlatform]: no platform channel or device needed to
  /// exercise the per-platform branch.
  ///
  /// iOS has no public Bluetooth Classic API, so classicFirst degrades to a
  /// single `{ble}` round there (see [ScanStrategy.classicFirst]); every
  /// other platform gets a real `{classic}` round 1.
  static Set<ConnectionType> roundOneTypes({required bool isIOS}) => isIOS
      ? const <ConnectionType>{ConnectionType.ble}
      : const <ConnectionType>{ConnectionType.classic};

  Future<void> _runStart({
    required Duration timeout,
    required Set<ConnectionType> types,
    required bool includeBonded,
    required bool includeUnnamed,
    required ScanStrategy strategy,
  }) async {
    try {
      _emitTimer?.cancel();
      _emitTimer = null;
      _dedup.clear();
      _includeBonded = includeBonded;
      _includeUnnamed = includeUnnamed;
      _devicesSubject.add(const <PrintlyDevice>[]);
      _isScanningSubject.add(true);

      // classicFirst only means something where Classic exists; on iOS it
      // silently degrades to a plain single {ble} round (see [ScanStrategy]).
      _classicFirstActive =
          strategy == ScanStrategy.classicFirst && !Platform.isIOS;
      _fallbackRoundDone = false;
      _activeTimeout = timeout;

      final Set<ConnectionType> round1Types =
          strategy == ScanStrategy.classicFirst
          ? roundOneTypes(isIOS: Platform.isIOS)
          : types;

      await _platform.startScan(
        types: round1Types,
        includeUnnamed: includeUnnamed,
      );
      _timeoutTimer?.cancel();
      _timeoutTimer = Timer(timeout, _onScanWindowElapsed);
    } catch (_) {
      _isScanningSubject.add(false);
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
      rethrow;
    } finally {
      _pendingStart = null;
    }
  }

  /// Called when a round's timeout timer fires. Routes to a normal stop, or
  /// — mid [ScanStrategy.classicFirst] with the fallback round not yet
  /// started — decides whether round 1 already found a printer or a BLE
  /// fallback round is needed. See [ScanStrategy.classicFirst] for the full
  /// contract; [_fallbackRoundDone] is what guarantees a third round never
  /// happens.
  void _onScanWindowElapsed() {
    if (_classicFirstActive && !_fallbackRoundDone) {
      final bool foundNamedDevice = _dedup.values.any(
        (PrintlyDevice device) => device.hasName && device.seenInScan,
      );
      if (foundNamedDevice) {
        unawaited(stopScan());
      } else {
        unawaited(_runFallbackRound());
      }
      return;
    }
    unawaited(stopScan());
  }

  /// Transitions from the Classic round to the BLE fallback round: stops the
  /// native Classic scan, starts a native BLE scan, and re-arms the timeout
  /// timer for the same duration round 1 used. [_dedup] and
  /// [_isScanningSubject] are deliberately left untouched — the accumulated
  /// device list survives the transition and callers never see `isScanning`
  /// flip to `false` in between, so this reads as one continuous scan.
  ///
  /// If a manual [stopScan] completes while this transition is in flight
  /// (native calls are async — the transition holds neither [_pendingStart]
  /// nor [_pendingStop], so a public [stopScan] races it freely),
  /// [isScanning] observes `false` once we regain control and the
  /// transition is abandoned instead of resurrecting a scan the caller just
  /// asked to stop. There are two places this can be observed, and both
  /// matter:
  /// - Between this round's own `stopScan()` and its `startScan()`: round 2
  ///   must simply never start. The check below the first `await` covers
  ///   this.
  /// - Between this round's `startScan()` dispatch and the check right
  ///   after it: the concurrent stop's native `stopScan()` call raced (and
  ///   lost) against this round's `startScan()`, so a BLE scan is now
  ///   running natively with nothing left to stop it — every future public
  ///   [stopScan] short-circuits once it observes `isScanning` already
  ///   `false`. Left alone this orphans the radio in a scan that runs
  ///   forever, invisible to the caller. So this path explicitly issues its
  ///   own best-effort `stopScan()` before bailing out.
  Future<void> _runFallbackRound() async {
    _fallbackRoundDone = true;
    try {
      await _platform.stopScan();
      // Pre-start hole: a concurrent stop landed between the transition's
      // own stopScan() (above) and startScan() (below) — round 2 must not
      // start at all.
      if (_disposed || !isScanning) return;
      await _platform.startScan(
        types: const <ConnectionType>{ConnectionType.ble},
        includeUnnamed: _includeUnnamed,
      );
      // Post-start hole: a concurrent stop raced this startScan() and lost,
      // so the native BLE scan we just started is orphaned unless we stop
      // it ourselves here — see the doc comment above for why.
      if (_disposed || !isScanning) {
        try {
          await _platform.stopScan();
        } catch (_) {
          // Best-effort: the goal is not leaking the radio, not surfacing a
          // redundant stop failure on top of whatever already happened.
        }
        return;
      }
      _timeoutTimer?.cancel();
      _timeoutTimer = Timer(_activeTimeout!, _onScanWindowElapsed);
    } catch (error) {
      if (_disposed) return;
      _scanErrorsSubject.add(_typedScanError(error));
      _isScanningSubject.add(false);
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
    }
  }

  /// Stops the current native scan, if any. Safe to call when no scan is
  /// running (returns a completed future without touching the platform).
  /// Concurrent [stopScan] calls share a single pending future.
  Future<void> stopScan() {
    _assertNotDisposed();
    if (_pendingStop != null) return _pendingStop!;
    if (!isScanning && _pendingStart == null) return Future<void>.value();

    _pendingStop = _runStop();
    return _pendingStop!;
  }

  Future<void> _runStop() async {
    try {
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
      await _platform.stopScan();
    } finally {
      // Flush any coalesced update so the final list is complete, not up to
      // one interval stale.
      _emitTimer?.cancel();
      _emitTimer = null;
      if (!_disposed) {
        _devicesSubject.add(List<PrintlyDevice>.unmodifiable(_dedup.values));
      }
      _isScanningSubject.add(false);
      _pendingStop = null;
    }
  }

  /// Clears the accumulated device list without touching the current scan
  /// status. Useful for example apps that expose a "clear list" button.
  void clearDevices() {
    _assertNotDisposed();
    _emitTimer?.cancel();
    _emitTimer = null;
    _dedup.clear();
    _devicesSubject.add(const <PrintlyDevice>[]);
  }

  void _onDeviceDiscovered(PrintlyDevice device) {
    if (_disposed) return;
    // Android's BluetoothLeScanner.stopScan() is asynchronous: results
    // buffered on the event channel keep landing after [_runStop] has
    // published `isScanning: false`, silently growing the "final" list a
    // consumer just rendered (measured in the field: 115 → 141 entries
    // after "scan finished"). Dropping them here keeps the stop terminal.
    // Results arriving while a stop is merely in flight are unaffected —
    // [_runStop] flips [isScanning] only after the native call returns —
    // and the classicFirst round transition deliberately holds [isScanning]
    // `true`, so round-2 results are unaffected too.
    if (!isScanning) return;
    if (!_includeBonded && !device.seenInScan) return;
    // Defense in depth over the native unnamed filter: nameless BLE
    // sightings of UNKNOWN devices never reach consumers, even from a
    // platform implementation that predates (or skips) the native-side
    // filtering. Two deliberate exemptions:
    // - Classic sightings: Android inquiry may report the name in a later
    //   follow-up broadcast, so an early nameless Classic sighting can
    //   still become a real printer once [PrintlyDevice.mergeWith] fills
    //   the name in.
    // - Already-known devices: real peripherals alternate between frames
    //   with and without the local name (the name often rides the scan
    //   response only), so a nameless re-sighting of a device the list
    //   already shows is an RSSI/transport refresh, not noise.
    if (!_includeUnnamed &&
        !device.hasName &&
        !device.availableTransports.contains(ConnectionType.classic) &&
        !_dedup.containsKey(device.dedupKey)) {
      return;
    }
    final PrintlyDevice? existing = _dedup[device.dedupKey];
    final PrintlyDevice merged = existing == null
        ? device
        : existing.mergeWith(device);
    _dedup[device.dedupKey] = merged;
    _scheduleEmit();
  }

  /// Coalesces the potentially high-frequency discovery callbacks into at most
  /// one list emission per [_emitInterval]. A zero interval emits immediately
  /// (used by tests for deterministic, synchronous assertions).
  void _scheduleEmit() {
    if (_emitInterval == Duration.zero) {
      _flushEmit();
      return;
    }
    if (_emitTimer != null) return;
    _emitTimer = Timer(_emitInterval, _flushEmit);
  }

  void _flushEmit() {
    _emitTimer = null;
    if (_disposed) return;
    final List<PrintlyDevice> next = List<PrintlyDevice>.unmodifiable(
      _dedup.values,
    );
    // Skip emissions that would only refresh RSSI. In a 140-device
    // environment every re-advertisement re-emitted the full list 4x/s and
    // consumers ended up writing their own diff just to silence state
    // churn. Identity, name, bonding, seenInScan or transport changes all
    // still emit; the freshest RSSI is always available synchronously via
    // [currentDevices], and the final post-stop flush in [_runStop] bypasses
    // this check entirely.
    if (_sameMeaningfully(next, _devicesSubject.value)) return;
    _devicesSubject.add(next);
  }

  /// Whether [next] differs from [previous] in anything a list UI renders —
  /// everything except [PrintlyDevice.rssi]. Order-sensitive by design:
  /// [_dedup] preserves insertion order, so a reorder implies a rebuild.
  static bool _sameMeaningfully(
    List<PrintlyDevice> next,
    List<PrintlyDevice> previous,
  ) {
    if (next.length != previous.length) return false;
    for (int i = 0; i < next.length; i++) {
      final PrintlyDevice a = next[i];
      final PrintlyDevice b = previous[i];
      if (a.address != b.address ||
          a.name != b.name ||
          a.isBonded != b.isBonded ||
          a.seenInScan != b.seenInScan ||
          a.availableTransports.length != b.availableTransports.length ||
          !a.availableTransports.containsAll(b.availableTransports)) {
        return false;
      }
    }
    return true;
  }

  void _onScanError(Object error, StackTrace stack) {
    if (_disposed) return;
    _scanErrorsSubject.add(_typedScanError(error));
    _isScanningSubject.add(false);
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  /// Converts a raw event-channel error into the shared typed model. Event
  /// channels deliver failures as [PlatformException]; anything else is
  /// wrapped verbatim so no failure is ever silently dropped.
  static PrintlyException _typedScanError(Object error) {
    if (error is! PlatformException) {
      return PrintlyScanException(PrintlyErrorCode.unknown, error.toString());
    }
    PrintlyErrorCode code = PrintlyErrorCode.fromWireName(error.message);
    if (code == PrintlyErrorCode.unknown) {
      code = PrintlyErrorCode.fromWireName(error.code);
    }
    final String message = error.message ?? error.code;
    if (code == PrintlyErrorCode.permissionDenied) {
      return PrintlyPermissionException(message);
    }
    return PrintlyScanException(code, message);
  }

  void _assertNotDisposed() {
    if (_disposed) {
      throw StateError('ScanController used after dispose()');
    }
  }

  /// Releases the internal stream subscriptions, timers, and subjects.
  /// Primarily used in tests — the production singleton lives for the
  /// process lifetime and does not need disposal.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _emitTimer?.cancel();
    _emitTimer = null;
    await _resultsSubscription?.cancel();
    _resultsSubscription = null;
    await _devicesSubject.close();
    await _isScanningSubject.close();
    await _scanErrorsSubject.close();
  }
}

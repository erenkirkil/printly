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
  List<PrintlyDevice> get currentDevices => _devicesSubject.value;

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
  Future<void> startScan({
    Duration? timeout,
    Set<ConnectionType>? types,
    bool includeBonded = true,
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
            ),
          );
      return _pendingStart!;
    }
    if (isScanning) return Future<void>.value();

    _pendingStart = _runStart(
      timeout: effectiveTimeout,
      types: effectiveTypes,
      includeBonded: includeBonded,
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

  Future<void> _runStart({
    required Duration timeout,
    required Set<ConnectionType> types,
    required bool includeBonded,
  }) async {
    try {
      _emitTimer?.cancel();
      _emitTimer = null;
      _dedup.clear();
      _includeBonded = includeBonded;
      _devicesSubject.add(const <PrintlyDevice>[]);
      _isScanningSubject.add(true);
      await _platform.startScan(types: types);
      _timeoutTimer?.cancel();
      _timeoutTimer = Timer(timeout, () {
        unawaited(stopScan());
      });
    } catch (_) {
      _isScanningSubject.add(false);
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
      rethrow;
    } finally {
      _pendingStart = null;
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
    if (!_includeBonded && !device.seenInScan) return;
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
    _devicesSubject.add(List<PrintlyDevice>.unmodifiable(_dedup.values));
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

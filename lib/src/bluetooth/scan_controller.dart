import 'dart:async';

import 'package:rxdart/rxdart.dart';

import '../core/connection_type.dart';
import '../core/printly_device.dart';
import '../platform/printly_platform_interface.dart';

/// Default timeout for [ScanController.startScan] when the caller does not
/// provide one. Chosen to align with Android 8+ BLE scan windowing, which
/// throttles opportunistic scans after ~30 seconds.
const Duration kDefaultScanTimeout = Duration(seconds: 30);

/// Default set of transports to scan when the caller passes no explicit
/// preference. Network scanning is intentionally excluded — network printers
/// are added directly via [PrintlyDevice.network].
const Set<ConnectionType> kDefaultScanTypes = <ConnectionType>{
  ConnectionType.classic,
  ConnectionType.ble,
};

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
  ScanController({PrintlyPlatform? platform})
    : _platform = platform ?? PrintlyPlatform.instance {
    _resultsSubscription = _platform.scanResults.listen(
      _onDeviceDiscovered,
      onError: _onScanError,
    );
  }

  final PrintlyPlatform _platform;

  final BehaviorSubject<List<PrintlyDevice>> _devicesSubject =
      BehaviorSubject<List<PrintlyDevice>>.seeded(const <PrintlyDevice>[]);
  final BehaviorSubject<bool> _isScanningSubject = BehaviorSubject<bool>.seeded(
    false,
  );

  final Map<String, PrintlyDevice> _dedup = <String, PrintlyDevice>{};

  StreamSubscription<PrintlyDevice>? _resultsSubscription;
  Timer? _timeoutTimer;
  Future<void>? _pendingStart;
  Future<void>? _pendingStop;
  bool _disposed = false;

  /// Broadcast stream of the currently known devices, deduplicated and
  /// emitted as an immutable list on each change.
  Stream<List<PrintlyDevice>> get devicesStream => _devicesSubject.stream;

  /// Broadcast stream signalling whether a native scan is in progress.
  Stream<bool> get isScanningStream => _isScanningSubject.stream;

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
  /// parallel native scans or leak timers.
  Future<void> startScan({
    Duration timeout = kDefaultScanTimeout,
    Set<ConnectionType> types = kDefaultScanTypes,
  }) {
    _assertNotDisposed();
    if (_pendingStart != null) return _pendingStart!;
    if (isScanning) return Future<void>.value();

    _pendingStart = _runStart(timeout: timeout, types: types);
    return _pendingStart!;
  }

  Future<void> _runStart({
    required Duration timeout,
    required Set<ConnectionType> types,
  }) async {
    try {
      _dedup.clear();
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
      _isScanningSubject.add(false);
      _pendingStop = null;
    }
  }

  /// Clears the accumulated device list without touching the current scan
  /// status. Useful for example apps that expose a "clear list" button.
  void clearDevices() {
    _assertNotDisposed();
    _dedup.clear();
    _devicesSubject.add(const <PrintlyDevice>[]);
  }

  void _onDeviceDiscovered(PrintlyDevice device) {
    if (_disposed) return;
    final PrintlyDevice? existing = _dedup[device.dedupKey];
    final PrintlyDevice merged = existing == null
        ? device
        : existing.copyWith(
            name: device.name ?? existing.name,
            rssi: device.rssi ?? existing.rssi,
            isBonded: device.isBonded || existing.isBonded,
          );
    _dedup[device.dedupKey] = merged;
    _devicesSubject.add(List<PrintlyDevice>.unmodifiable(_dedup.values));
  }

  void _onScanError(Object error, StackTrace stack) {
    if (_disposed) return;
    _isScanningSubject.add(false);
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
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
    await _resultsSubscription?.cancel();
    _resultsSubscription = null;
    await _devicesSubject.close();
    await _isScanningSubject.close();
  }
}

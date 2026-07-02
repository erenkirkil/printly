import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:permission_handler/permission_handler.dart' as ph;

import 'bluetooth/bluetooth_adapter_state.dart';
import 'bluetooth/bluetooth_manager.dart';
import 'bluetooth/connection_controller.dart';
import 'bluetooth/last_device_store.dart';
import 'bluetooth/scan_controller.dart';
import 'core/connection_state.dart';
import 'core/connection_type.dart';
import 'core/printly_device.dart';
import 'core/printly_exception.dart';
import 'core/printly_permission_status.dart';
import 'platform/printly_platform_interface.dart';
import 'print/print_config.dart';
import 'print/print_job.dart';
import 'print/printly_paper_width.dart';

/// Entry point for the `printly` SDK.
///
/// Access the SDK through the [Printly.instance] singleton. Public methods
/// are added progressively across sprints (see `docs/sprints.md`). Calls to
/// not-yet-implemented APIs throw [UnimplementedError].
class Printly {
  Printly._() {
    // Bound unconditionally so that a plain connect() persists the device
    // even when no store-touching API was ever called first.
    _bindActiveDeviceListener();
  }

  /// Test-only constructor producing an isolated facade. Production code
  /// must use [instance]; each call creates fresh controllers bound to the
  /// current [PrintlyPlatform.instance].
  @visibleForTesting
  factory Printly.forTesting() = Printly._;

  /// The shared [Printly] singleton.
  static final Printly instance = Printly._();

  final BluetoothManager _bluetooth = BluetoothManager();
  final ScanController _scan = ScanController();
  final ConnectionController _connection = ConnectionController();

  Future<LastDeviceStore>? _storeFuture;
  LastDeviceStore? _cachedStore;
  PrintlyDevice? _cachedLastDevice;
  bool _autoReconnectEnabled = false;
  StreamSubscription<PrintlyDevice?>? _activeDeviceSub;
  StreamSubscription<BluetoothAdapterState>? _autoReconnectAdapterSub;

  Future<LastDeviceStore> _openStore() async {
    final Future<LastDeviceStore> future = _storeFuture ??=
        LastDeviceStore.open();
    final LastDeviceStore store;
    try {
      store = await future;
    } catch (_) {
      // Evict the failed future so the next call retries instead of
      // rethrowing the same stale error for the rest of the session.
      if (identical(_storeFuture, future)) {
        _storeFuture = null;
      }
      rethrow;
    }
    if (_cachedStore == null) {
      _cachedStore = store;
      // A device connected in this session is fresher than the persisted one.
      _cachedLastDevice ??= store.readDevice();
      _autoReconnectEnabled = store.readAutoReconnect();
      if (_autoReconnectEnabled) {
        // Restoring the flag alone is not enough — without the adapter
        // subscription the persisted preference would never act.
        _armAutoReconnect();
      }
    }
    return store;
  }

  void _bindActiveDeviceListener() {
    _activeDeviceSub ??= _connection.activeDeviceStream.listen((
      PrintlyDevice? device,
    ) async {
      if (device == null) return;
      _cachedLastDevice = device;
      try {
        final LastDeviceStore store = await _openStore();
        await store.writeDevice(device);
      } catch (_) {
        // Persistence is best-effort: a storage failure must never surface
        // as an unhandled async error out of a successful connect.
      }
    });
  }

  void _armAutoReconnect() {
    _autoReconnectAdapterSub ??= _bluetooth.stream.listen(
      _onAdapterStateChangedForReconnect,
    );
  }

  /// Returns the underlying native platform version string.
  ///
  /// Intended as a smoke test during early development. Will be replaced
  /// by real capability queries in later sprints.
  Future<String?> getPlatformVersion() {
    return PrintlyPlatform.instance.getPlatformVersion();
  }

  /// Broadcast stream of [BluetoothAdapterState] changes.
  ///
  /// Subscribing to this stream starts the native adapter observer. On
  /// iOS this also triggers the system Bluetooth permission prompt if the
  /// app has not yet been authorised and
  /// `NSBluetoothAlwaysUsageDescription` is present in the Info.plist.
  Stream<BluetoothAdapterState> get adapterState => _bluetooth.stream;

  /// Most recently observed [BluetoothAdapterState].
  ///
  /// Returns [BluetoothAdapterState.unknown] until the first event is
  /// received, which requires an active subscription to [adapterState].
  BluetoothAdapterState get currentAdapterState => _bluetooth.currentState;

  /// Whether Bluetooth is currently powered on and usable.
  ///
  /// Mirrors `currentAdapterState == BluetoothAdapterState.poweredOn`.
  /// Because the cache is only populated while [adapterState] has at
  /// least one active subscriber, this getter returns `false` until the
  /// first event arrives.
  bool get isBluetoothAvailable => _bluetooth.isBluetoothAvailable;

  /// Requests the runtime permissions required to use Bluetooth on the
  /// current platform.
  ///
  /// On Android 12+ (API 31+) this asks only for `BLUETOOTH_SCAN` and
  /// `BLUETOOTH_CONNECT`; on Android 11 and earlier it asks for `BLUETOOTH`
  /// and `ACCESS_FINE_LOCATION`. Requesting the legacy/location permissions on
  /// Android 12+ would report `denied` (they are capped at `maxSdkVersion=30`
  /// in the manifest) and wrongly poison the aggregate, so the request set is
  /// chosen by the device API level. On iOS it returns the current Bluetooth
  /// authorisation status — the actual prompt is triggered the first time a
  /// consumer subscribes to [adapterState].
  ///
  /// Returns the aggregate worst status across the requested permissions
  /// (e.g. if one is `permanentlyDenied` the overall result is
  /// `permanentlyDenied`).
  Future<PrintlyPermissionStatus> requestPermissions() async {
    final List<ph.Permission> required;
    if (Platform.isAndroid) {
      final int sdkInt = await PrintlyPlatform.instance.getAndroidSdkInt();
      required = sdkInt >= 31
          ? <ph.Permission>[
              ph.Permission.bluetoothScan,
              ph.Permission.bluetoothConnect,
            ]
          : <ph.Permission>[
              ph.Permission.bluetooth,
              ph.Permission.locationWhenInUse,
            ];
    } else {
      required = <ph.Permission>[ph.Permission.bluetooth];
    }

    final Map<ph.Permission, ph.PermissionStatus> results = await required
        .request();
    return _aggregateStatus(results.values.map(_toPrintlyStatus));
  }

  /// Opens the system Bluetooth settings page.
  ///
  /// On Android this uses `Settings.ACTION_BLUETOOTH_SETTINGS`. iOS offers
  /// no public deep link to the Bluetooth pane, so the app's own settings
  /// page is opened instead.
  Future<bool> openBluetoothSettings() {
    return PrintlyPlatform.instance.openBluetoothSettings();
  }

  /// Opens this application's system settings page so the user can review
  /// or change granted permissions. Delegates to
  /// [ph.openAppSettings].
  Future<bool> openAppSettings() => ph.openAppSettings();

  /// Starts a device scan across the requested transport [types]. Defaults to
  /// scanning both Bluetooth Classic and BLE for [kDefaultScanTimeout]; the
  /// scan auto-stops when the timeout elapses.
  ///
  /// Safe to call repeatedly — concurrent calls share a single native scan
  /// and the same in-flight future, so duplicate button taps cannot start
  /// parallel scans.
  Future<void> startScan({
    Duration timeout = kDefaultScanTimeout,
    Set<ConnectionType> types = kDefaultScanTypes,
  }) => _scan.startScan(timeout: timeout, types: types);

  /// Stops any in-progress scan. A no-op when no scan is running.
  Future<void> stopScan() => _scan.stopScan();

  /// Broadcast stream of discovered devices, deduplicated by transport +
  /// address and emitted as an immutable list on each change.
  Stream<List<PrintlyDevice>> get devicesStream => _scan.devicesStream;

  /// Broadcast stream signalling whether a scan is currently running.
  Stream<bool> get isScanningStream => _scan.isScanningStream;

  /// Broadcast stream of asynchronous scan failures (Bluetooth toggled off
  /// mid-scan, native scan-failed callbacks). Without subscribing here, such
  /// a failure is indistinguishable from a normal timeout stop — see
  /// [ScanController.scanErrors].
  Stream<PrintlyException> get scanErrorsStream => _scan.scanErrors;

  /// Synchronous snapshot of the currently known devices.
  List<PrintlyDevice> get currentDevices => _scan.currentDevices;

  /// Synchronous snapshot of [isScanningStream].
  bool get isScanning => _scan.isScanning;

  /// Clears the accumulated device list without stopping an active scan.
  void clearDevices() => _scan.clearDevices();

  /// Opens a link to [device]. Idempotent for duplicate taps and serialises
  /// switching between two devices (disconnect current, then connect new).
  ///
  /// Completes with a [PrintlyConnectionException] when the attempt fails
  /// (its [PrintlyException.code] distinguishes timeouts, refusals, and
  /// dropped links) and with a [PrintlyUnsupportedException] for
  /// [ConnectionType.network] devices — the network transport ships in a
  /// later release.
  Future<void> connect(
    PrintlyDevice device, {
    Duration timeout = kDefaultConnectTimeout,
  }) async {
    if (device.type == ConnectionType.network) {
      // Fail fast with a typed error instead of a native round-trip that
      // would reject with the same reason after a delay.
      throw const PrintlyUnsupportedException(
        PrintlyErrorCode.networkNotSupported,
        'Network (Ethernet/WiFi) printing is not implemented yet.',
      );
    }
    return _connection.connect(device, timeout: timeout);
  }

  /// Closes the current link. When [device] is omitted, disconnects the
  /// currently active device (if any).
  Future<void> disconnect({PrintlyDevice? device}) =>
      _connection.disconnect(device: device);

  /// Per-device broadcast stream of [ConnectionState] transitions.
  Stream<ConnectionState> connectionStateOf(PrintlyDevice device) =>
      _connection.connectionStateOf(device);

  /// Synchronous snapshot of the current [ConnectionState] for [device].
  ConnectionState connectionStateSnapshotOf(PrintlyDevice device) =>
      _connection.stateOf(device);

  /// Broadcast stream of the currently-connected device (or `null`).
  Stream<PrintlyDevice?> get activeDeviceStream =>
      _connection.activeDeviceStream;

  /// Synchronous snapshot of [activeDeviceStream].
  PrintlyDevice? get activeDevice => _connection.activeDevice;

  /// Most recent failure reason reported for [device], cleared on the next
  /// successful connect.
  String? lastFailureReasonOf(PrintlyDevice device) =>
      _connection.lastFailureReasonOf(device);

  /// Creates a new [PrintJob] for the given paper width.
  ///
  /// Loads (and caches) the ESC/POS capability profile, so the first call may
  /// await a one-time asset read. When [config] is supplied its
  /// [PrintConfig.paperWidth] takes precedence over the [paperWidth] argument.
  Future<PrintJob> newJob({
    PrintlyPaperWidth paperWidth = PrintlyPaperWidth.mm58,
    PrintConfig? config,
  }) => PrintJob.create(paperWidth: paperWidth, config: config);

  /// Serialises [job] and writes it to [device] over the open connection.
  /// Build the [job] with [newJob].
  ///
  /// Rejects with a [PrintlyWriteException] whose [PrintlyException.code]
  /// is one of [PrintlyErrorCode.notConnected] (connect first),
  /// [PrintlyErrorCode.notReady] (BLE link up but not writable yet),
  /// [PrintlyErrorCode.writeBusy] (previous write still in flight),
  /// [PrintlyErrorCode.writeTimeout] (printer stopped acknowledging —
  /// usually worth a reconnect + retry), [PrintlyErrorCode.disconnected],
  /// or [PrintlyErrorCode.writeFailed]. On iOS printing ships in a later
  /// release and currently rejects with a [PrintlyUnsupportedException].
  Future<void> print(PrintlyDevice device, PrintJob job) {
    return PrintlyPlatform.instance.write(device: device, bytes: job.build());
  }

  /// Loads the last persisted device and auto-reconnect flag, caches them
  /// in-memory, and returns the device (or `null`).
  ///
  /// Safe to call multiple times — subsequent calls are cheap and return
  /// the cached value without hitting the storage backend.
  Future<PrintlyDevice?> loadLastConnectedDevice() async {
    await _openStore();
    return _cachedLastDevice;
  }

  /// Synchronously returns the in-memory cached last-connected device.
  /// Returns `null` until [loadLastConnectedDevice], [reconnectLastDevice],
  /// [enableAutoReconnect], or a successful [connect] has populated the
  /// cache.
  PrintlyDevice? get lastConnectedDevice => _cachedLastDevice;

  /// Clears the persisted last-connected device and any cached value.
  Future<void> forgetLastConnectedDevice() async {
    final LastDeviceStore store = await _openStore();
    _cachedLastDevice = null;
    await store.writeDevice(null);
  }

  /// Reconnects to the last persisted device. Returns `false` if no device
  /// has ever been remembered.
  Future<bool> reconnectLastDevice({
    Duration timeout = kDefaultConnectTimeout,
  }) async {
    await _openStore();
    final PrintlyDevice? device = _cachedLastDevice;
    if (device == null) return false;
    await _connection.connect(device, timeout: timeout);
    return true;
  }

  /// Enables or disables opt-in auto-reconnect.
  ///
  /// When enabled, the SDK listens to the adapter state and retries the
  /// persisted device once whenever the adapter transitions to
  /// [BluetoothAdapterState.poweredOn]. When [persist] is true the flag is
  /// stored in [SharedPreferences] and restored on the next app launch.
  Future<void> enableAutoReconnect({
    required bool enabled,
    bool persist = true,
  }) async {
    final LastDeviceStore store = await _openStore();
    _autoReconnectEnabled = enabled;
    if (persist) {
      await store.writeAutoReconnect(enabled: enabled);
    }
    if (enabled) {
      _armAutoReconnect();
    } else {
      await _autoReconnectAdapterSub?.cancel();
      _autoReconnectAdapterSub = null;
    }
  }

  /// Whether auto-reconnect is currently enabled. Reflects the persisted
  /// value once [loadLastConnectedDevice] or [enableAutoReconnect] has been
  /// called; otherwise defaults to `false`.
  bool get isAutoReconnectEnabled => _autoReconnectEnabled;

  void _onAdapterStateChangedForReconnect(BluetoothAdapterState state) {
    if (!_autoReconnectEnabled) return;
    if (state != BluetoothAdapterState.poweredOn) return;
    final PrintlyDevice? device = _cachedLastDevice;
    if (device == null) return;
    if (_connection.stateOf(device) == ConnectionState.connected) return;
    unawaited(_connection.connect(device).catchError((_) {}));
  }

  /// Maps `permission_handler`'s status into printly's own enum so the
  /// third-party type never leaks into the public API surface.
  static PrintlyPermissionStatus _toPrintlyStatus(ph.PermissionStatus status) {
    switch (status) {
      case ph.PermissionStatus.granted:
        return PrintlyPermissionStatus.granted;
      case ph.PermissionStatus.denied:
        return PrintlyPermissionStatus.denied;
      case ph.PermissionStatus.permanentlyDenied:
        return PrintlyPermissionStatus.permanentlyDenied;
      case ph.PermissionStatus.restricted:
        return PrintlyPermissionStatus.restricted;
      case ph.PermissionStatus.limited:
        return PrintlyPermissionStatus.limited;
      case ph.PermissionStatus.provisional:
        return PrintlyPermissionStatus.provisional;
    }
  }

  static PrintlyPermissionStatus _aggregateStatus(
    Iterable<PrintlyPermissionStatus> statuses,
  ) {
    if (statuses.isEmpty) {
      return PrintlyPermissionStatus.denied;
    }
    return statuses.reduce(_worse);
  }

  static PrintlyPermissionStatus _worse(
    PrintlyPermissionStatus a,
    PrintlyPermissionStatus b,
  ) {
    return _severity(a) >= _severity(b) ? a : b;
  }

  static int _severity(PrintlyPermissionStatus status) {
    switch (status) {
      case PrintlyPermissionStatus.permanentlyDenied:
        return 4;
      case PrintlyPermissionStatus.restricted:
        return 3;
      case PrintlyPermissionStatus.denied:
        return 2;
      case PrintlyPermissionStatus.provisional:
        return 1;
      case PrintlyPermissionStatus.limited:
        return 1;
      case PrintlyPermissionStatus.granted:
        return 0;
    }
  }
}

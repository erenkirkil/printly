import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:permission_handler/permission_handler.dart' as ph;

import 'bluetooth/bluetooth_adapter_state.dart';
import 'bluetooth/bluetooth_manager.dart';
import 'bluetooth/connection_controller.dart';
import 'bluetooth/last_device_store.dart';
import 'bluetooth/scan_controller.dart';
import 'bluetooth/scan_session.dart';
import 'core/bluetooth_permission_set.dart';
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

  /// Ref-count registry for every [PrintlyScanSession] created through
  /// [newScanSession], scoped to this facade instance (and therefore to
  /// [_scan]) instead of being process-wide — see [ScanSessionRegistry].
  final ScanSessionRegistry _scanSessionRegistry = ScanSessionRegistry();

  /// Timeout applied to [startScan] calls that do not pass their own
  /// [Duration]. Starts at [kDefaultScanTimeout]; set it once per app
  /// (e.g. at startup) instead of repeating a custom timeout at every
  /// [startScan] call site.
  Duration defaultScanTimeout = kDefaultScanTimeout;

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
  ///
  /// On Android this stream reports the radio alone. Missing runtime
  /// permissions are **not** folded in (they were before 0.2.0, and froze
  /// the stream at `unauthorized`) — check them with [checkPermissions].
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

  Future<List<ph.Permission>> _requiredPermissions() async {
    if (!Platform.isAndroid) {
      return requiredBluetoothPermissions(isAndroid: false, sdkInt: 0);
    }
    final int sdkInt = await PrintlyPlatform.instance.getAndroidSdkInt();
    return requiredBluetoothPermissions(isAndroid: true, sdkInt: sdkInt);
  }

  /// Returns the current permission status **without prompting the user**.
  ///
  /// Evaluates exactly the same permission set as [requestPermissions]
  /// (chosen by platform and Android API level) and aggregates to the worst
  /// status. Use it to gate UI before deciding whether to show a rationale
  /// or call [requestPermissions] — calling this can never pop a system
  /// dialog. On iOS the status is read from
  /// `CBCentralManager.authorization` (a class property), so no central
  /// manager is created and the system Bluetooth prompt is not triggered.
  Future<PrintlyPermissionStatus> checkPermissions() async {
    final List<ph.Permission> required = await _requiredPermissions();
    final List<PrintlyPermissionStatus> statuses = <PrintlyPermissionStatus>[];
    for (final ph.Permission permission in required) {
      statuses.add(_toPrintlyStatus(await permission.status));
    }
    return _aggregateStatus(statuses);
  }

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
    final List<ph.Permission> required = await _requiredPermissions();
    final Map<ph.Permission, ph.PermissionStatus> results = await required
        .request();
    return _aggregateStatus(results.values.map(_toPrintlyStatus));
  }

  /// Opens the system Bluetooth settings page.
  ///
  /// On Android this uses `Settings.ACTION_BLUETOOTH_SETTINGS`. iOS offers
  /// no public deep link to the Bluetooth pane, so the app's own settings
  /// page is opened instead — **this cannot turn the radio on**. If the
  /// radio itself is off, use [requestEnableBluetooth] instead.
  Future<bool> openBluetoothSettings() {
    return PrintlyPlatform.instance.openBluetoothSettings();
  }

  /// Asks the user to turn Bluetooth on, in place, without leaving the app.
  ///
  /// On Android this shows the system `ACTION_REQUEST_ENABLE` dialog over
  /// the current activity — the app is never backgrounded. On Android 12+
  /// (API 31+) showing that dialog itself requires the `BLUETOOTH_CONNECT`
  /// runtime permission; when it is missing this rejects with a
  /// [PrintlyPermissionException] instead of silently doing nothing (call
  /// [requestPermissions] first, or check [checkPermissions]).
  ///
  /// On iOS there is no programmatic way to toggle the radio, and
  /// [openBluetoothSettings] cannot reach the system Bluetooth pane — Apple
  /// only exposes `App-Prefs:Bluetooth`, a private URL scheme that risks App
  /// Store rejection under guideline 2.5.1. Instead, this creates a
  /// short-lived `CBCentralManager` with the `CBCentralManagerOptionShowPowerAlertKey`
  /// option, which is Apple's one sanctioned "Bluetooth is off" system
  /// alert; that alert's own "Settings" button legitimately deep-links to
  /// the system Bluetooth pane, something this SDK cannot do on its own.
  ///
  /// **This call does not wait for the radio to actually turn on** — it
  /// only reports whether the system request was shown. Returns `false` as
  /// a no-op when Bluetooth is already on. Watch [adapterState] for the
  /// real outcome (the user may dismiss the prompt without enabling it).
  /// On iOS, `true` means the request was issued: the system may suppress
  /// the alert when the radio is already on (unknowable without instantiating
  /// a manager), and a never-authorized app gets the permission prompt instead.
  Future<bool> requestEnableBluetooth() {
    return PrintlyPlatform.instance.requestEnableBluetooth();
  }

  /// Whether the OS location service currently gates Bluetooth scanning on
  /// this device.
  ///
  /// This is **not** the same thing as the location *permission*. On Android
  /// below API 31, both Classic inquiry and BLE scanning silently return no
  /// results — with no error from the platform — when the location
  /// *service* is off, even if the location permission was granted. A scan
  /// in that state looks exactly like an empty room. [startScan] checks this
  /// itself and rejects with [PrintlyErrorCode.locationServicesDisabled]
  /// instead of scanning blind, so most callers do not need to call this
  /// directly — it is exposed for apps that want to check and route the user
  /// proactively, e.g. before showing a "scan" button.
  ///
  /// From API 31, printly declares `BLUETOOTH_SCAN` with the
  /// `neverForLocation` flag, which removes the dependency on the location
  /// service entirely — this always returns `true` there. iOS never depends
  /// on the location service for Bluetooth scanning either, so this always
  /// returns `true` on iOS.
  Future<bool> isLocationServiceEnabled() {
    return PrintlyPlatform.instance.isLocationServiceEnabled();
  }

  /// Opens the system location settings page so the user can turn the
  /// location service on.
  ///
  /// Android only, via `Settings.ACTION_LOCATION_SOURCE_SETTINGS`. Returns
  /// `false` as a no-op on iOS — this SDK does not touch CoreLocation, since
  /// creating a location manager would raise a permission question printly
  /// has no business asking.
  Future<bool> openLocationSettings() {
    return PrintlyPlatform.instance.openLocationSettings();
  }

  /// Opens this application's system settings page so the user can review
  /// or change granted permissions. Delegates to
  /// [ph.openAppSettings].
  Future<bool> openAppSettings() => ph.openAppSettings();

  /// Starts a device scan across the requested transport [types]. [timeout]
  /// defaults to [defaultScanTimeout] ([kDefaultScanTimeout] unless
  /// overridden); the scan auto-stops when it elapses. [types] defaults to
  /// the platform-appropriate set (`{classic, ble}` on Android, `{ble}` on
  /// iOS — see `ScanController.defaultScanTypesForPlatform`).
  ///
  /// When [includeBonded] is `false`, Classic bonded-cache seeds are
  /// excluded from [devicesStream] until they are actually seen by an
  /// inquiry — see [ScanController.startScan] for the full semantics.
  ///
  /// When [includeUnnamed] is `false` (the default) nameless BLE
  /// advertisements — overwhelmingly privacy-rotated phones, wearables and
  /// beacons, measured at 135 of 141 records in one office scan — are
  /// excluded, natively where possible so they never even cross the
  /// platform channel. A thermal printer must advertise its name to be
  /// pickable, so the default hides only what no user could choose. Pass
  /// `true` for diagnostic UIs that must show everything. Nameless
  /// *Classic* sightings are always kept (their name can arrive in a later
  /// inquiry broadcast), as are nameless re-sightings of devices already on
  /// the list (RSSI refreshes) — see [ScanController.startScan].
  ///
  /// [strategy] defaults to [ScanStrategy.parallel]. Pass
  /// [ScanStrategy.classicFirst] to scan Classic first on Android and only
  /// fall back to a single BLE round when nothing named answered — see
  /// [ScanStrategy.classicFirst] for the full contract, including how it
  /// interacts with an explicit [types].
  ///
  /// Safe to call repeatedly — concurrent calls share a single native scan
  /// and the same in-flight future, so duplicate button taps cannot start
  /// parallel scans.
  Future<void> startScan({
    Duration? timeout,
    Set<ConnectionType>? types,
    bool includeBonded = true,
    bool includeUnnamed = false,
    ScanStrategy strategy = ScanStrategy.parallel,
  }) => _scan.startScan(
    timeout: timeout ?? defaultScanTimeout,
    types: types,
    includeBonded: includeBonded,
    includeUnnamed: includeUnnamed,
    strategy: strategy,
  );

  /// Stops any in-progress scan. A no-op when no scan is running.
  ///
  /// Shares the same native scan as every [PrintlyScanSession] created via
  /// [newScanSession]: this also ends the scan for any active sessions
  /// (their `isScanning` observes `false`), regardless of whether the scan
  /// was originally started here or through a session.
  Future<void> stopScan() => _scan.stopScan();

  /// Broadcast stream of discovered devices, deduplicated by address (Classic
  /// and BLE sightings of one radio merge into a single record) and emitted as
  /// an immutable list on each change.
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

  /// Creates a new screen-scoped [PrintlyScanSession].
  ///
  /// Unlike [devicesStream]/[isScanningStream] — process-lifetime streams
  /// that replay their last value into every new subscriber — a session
  /// seeds `devices`/`isScanning` empty/`false` and only starts forwarding
  /// controller events once its own `start()` is called. See
  /// [PrintlyScanSession] for the three field bugs this avoids. Create one
  /// per screen (e.g. in `initState`) and call `dispose()` on it (e.g. in
  /// `dispose`); an in-flight session's `start()` without an explicit
  /// `timeout` uses [defaultScanTimeout] at the time `start()` runs, not at
  /// the time this method was called.
  ///
  /// Sessions and this facade's own [startScan]/[stopScan] share one native
  /// scan — there is no per-session native scan. That has two consequences
  /// worth knowing: [stopScan] ends every active session's scan too, and an
  /// undisposed active session keeps this facade's session registry
  /// non-empty, which blocks the last-session auto-stop that would
  /// otherwise fire when every session using it has stopped — always
  /// `dispose()` a session (e.g. in your widget's `dispose()`), not just
  /// `stop()` it, once you are done with it.
  PrintlyScanSession newScanSession() => createScanSession(
    controller: _scan,
    registry: _scanSessionRegistry,
    resolveDefaultTimeout: () => defaultScanTimeout,
  );

  /// Opens a link to [device]. Idempotent for duplicate taps and serialises
  /// switching between two devices (disconnect current, then connect new).
  ///
  /// [transport] picks the [ConnectionType] to use when [device] advertises
  /// more than one (a dual-mode Classic + BLE radio). When omitted, the
  /// default preference is platform-specific: on Android, Classic is chosen
  /// when available — it is the field-proven, most reliable RFCOMM path for
  /// dual-mode printers; on iOS, only BLE is ever chosen (Classic requires
  /// MFi certification, which is out of scope). Pass
  /// `transport: ConnectionType.ble` explicitly on Android to opt into BLE
  /// for a dual-mode printer instead. See
  /// `ConnectionController.resolveTransport` for the full rule, and
  /// [transportOf] to read back what was actually chosen. Switching the
  /// transport of an already-connected device requires passing an explicit,
  /// different [transport] — connecting again with the same or no transport
  /// while already connected is a no-op.
  ///
  /// Completes with a [PrintlyConnectionException] when the attempt fails
  /// (its [PrintlyException.code] distinguishes timeouts, refusals, and
  /// dropped links) and with a [PrintlyUnsupportedException] for
  /// [ConnectionType.network] devices — the network transport ships in a
  /// later release.
  ///
  /// **Stop the scan first if one is running.** An in-flight scan is not
  /// cancelled here — silently ending something the app started would be a
  /// surprising side effect, and an app managing several printers may want to
  /// keep looking. But on Android a radio busy scanning while a GATT link is
  /// being established is a well-known cause of connection failures, and the
  /// scan is wasted battery once the printer has been found either way. Call
  /// [stopScan] before this in the ordinary single-printer case.
  /// A duplicate call while an attempt is in flight returns the pending
  /// future and ignores a differing explicit [transport].
  Future<void> connect(
    PrintlyDevice device, {
    ConnectionType? transport,
    Duration timeout = kDefaultConnectTimeout,
  }) async {
    if (device.availableTransports.contains(ConnectionType.network)) {
      // Fail fast with a typed error instead of a native round-trip that
      // would reject with the same reason after a delay.
      throw const PrintlyUnsupportedException(
        PrintlyErrorCode.networkNotSupported,
        'Network (Ethernet/WiFi) printing is not implemented yet.',
      );
    }
    return _connection.connect(device, transport: transport, timeout: timeout);
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

  /// The [ConnectionType] [connect] chose (or was told to use) for [device]:
  /// the active link's transport, or the last one used if [device] is
  /// currently disconnected. `null` if [device] has never been attempted
  /// this session.
  ConnectionType? transportOf(PrintlyDevice device) =>
      _connection.transportOf(device);

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
  /// or [PrintlyErrorCode.writeFailed]. Supported on both platforms:
  /// Android writes over Classic RFCOMM or BLE GATT, iOS over BLE
  /// (hardware-verified since 0.1.0).
  Future<void> print(PrintlyDevice device, PrintJob job) {
    // The write must travel over the same transport the active (or last)
    // connect() used — the native side keys the session by `type:address`.
    // transportOf() is null only when this device was never connected
    // through this controller; resolveTransport() re-derives the same
    // choice connect() would have made so a write attempt still gets a
    // sensible transport (and the native "not connected" error) instead of
    // an unrelated crash.
    final ConnectionType transport;
    try {
      transport =
          _connection.transportOf(device) ??
          ConnectionController.resolveTransport(device, isIOS: Platform.isIOS);
    } catch (error, stackTrace) {
      return Future<void>.error(error, stackTrace);
    }
    return PrintlyPlatform.instance.write(
      device: device,
      transport: transport,
      bytes: job.build(),
    );
  }

  /// Loads the last persisted device and auto-reconnect flag, caches them
  /// in-memory, and returns the device (or `null`).
  ///
  /// Safe to call multiple times — subsequent calls are cheap and return
  /// the cached value without hitting the storage backend.
  @Deprecated(
    'Will be removed in v1.0.0 along with the shared_preferences dependency. Persist the address and transport with your own storage and reconstruct the device via the public PrintlyDevice constructor — see the README section "Connecting without scanning".',
  )
  Future<PrintlyDevice?> loadLastConnectedDevice() async {
    await _openStore();
    return _cachedLastDevice;
  }

  /// Synchronously returns the in-memory cached last-connected device.
  /// Returns `null` until [loadLastConnectedDevice], [reconnectLastDevice],
  /// [enableAutoReconnect], or a successful [connect] has populated the
  /// cache.
  @Deprecated(
    'Will be removed in v1.0.0 along with the shared_preferences dependency. Persist the address and transport with your own storage and reconstruct the device via the public PrintlyDevice constructor — see the README section "Connecting without scanning".',
  )
  PrintlyDevice? get lastConnectedDevice => _cachedLastDevice;

  /// Clears the persisted last-connected device and any cached value.
  @Deprecated(
    'Will be removed in v1.0.0 along with the shared_preferences dependency. Persist the address and transport with your own storage and reconstruct the device via the public PrintlyDevice constructor — see the README section "Connecting without scanning".',
  )
  Future<void> forgetLastConnectedDevice() async {
    final LastDeviceStore store = await _openStore();
    _cachedLastDevice = null;
    await store.writeDevice(null);
  }

  /// Reconnects to the last persisted device. Returns `false` if no device
  /// has ever been remembered.
  @Deprecated(
    'Will be removed in v1.0.0 along with the shared_preferences dependency. Persist the address and transport with your own storage and reconstruct the device via the public PrintlyDevice constructor — see the README section "Connecting without scanning".',
  )
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
  @Deprecated(
    'Will be removed in v1.0.0 along with the shared_preferences dependency. Persist the address and transport with your own storage and reconstruct the device via the public PrintlyDevice constructor — see the README section "Connecting without scanning".',
  )
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
  @Deprecated(
    'Will be removed in v1.0.0 along with the shared_preferences dependency. Persist the address and transport with your own storage and reconstruct the device via the public PrintlyDevice constructor — see the README section "Connecting without scanning".',
  )
  bool get isAutoReconnectEnabled => _autoReconnectEnabled;

  void _onAdapterStateChangedForReconnect(BluetoothAdapterState state) {
    if (!_autoReconnectEnabled) return;
    if (state != BluetoothAdapterState.poweredOn) return;
    final PrintlyDevice? device = _cachedLastDevice;
    if (device == null) return;
    if (_connection.stateOf(device) == ConnectionState.connected) return;
    // Reconnect passes the remembered transport so an explicit BLE choice on a
    // dual-mode radio survives an adapter power-cycle instead of silently
    // reverting to the platform default.
    unawaited(
      _connection
          .connect(device, transport: _connection.transportOf(device))
          .catchError((_) {}),
    );
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

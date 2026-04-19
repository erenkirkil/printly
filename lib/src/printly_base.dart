import 'dart:async';
import 'dart:io' show Platform;

import 'package:permission_handler/permission_handler.dart' as ph;

import 'bluetooth/bluetooth_adapter_state.dart';
import 'bluetooth/bluetooth_manager.dart';
import 'platform/printly_platform_interface.dart';

/// Entry point for the `printly` SDK.
///
/// Access the SDK through the [Printly.instance] singleton. Public methods
/// are added progressively across sprints (see `docs/sprints.md`). Calls to
/// not-yet-implemented APIs throw [UnimplementedError].
class Printly {
  Printly._();

  /// The shared [Printly] singleton.
  static final Printly instance = Printly._();

  final BluetoothManager _bluetooth = BluetoothManager();

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
  /// On Android 12+ this asks for `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT`;
  /// on Android 11 and earlier it asks for `BLUETOOTH` and
  /// `ACCESS_FINE_LOCATION`. On iOS it returns the current Bluetooth
  /// authorisation status — the actual prompt is triggered the first time
  /// a consumer subscribes to [adapterState].
  ///
  /// Returns the aggregate worst status across the requested permissions
  /// (e.g. if one is `permanentlyDenied` the overall result is
  /// `permanentlyDenied`).
  Future<ph.PermissionStatus> requestPermissions() async {
    final List<ph.Permission> required = Platform.isAndroid
        ? <ph.Permission>[
            ph.Permission.bluetoothScan,
            ph.Permission.bluetoothConnect,
            ph.Permission.bluetooth,
            ph.Permission.locationWhenInUse,
          ]
        : <ph.Permission>[ph.Permission.bluetooth];

    final Map<ph.Permission, ph.PermissionStatus> results = await required
        .request();
    return _aggregateStatus(results.values);
  }

  /// Opens the system Bluetooth settings page.
  ///
  /// On Android this uses `Settings.ACTION_BLUETOOTH_SETTINGS`; on iOS it
  /// opens the app-level Bluetooth settings pane via the
  /// `App-Prefs:Bluetooth` URL scheme.
  Future<bool> openBluetoothSettings() {
    return PrintlyPlatform.instance.openBluetoothSettings();
  }

  /// Opens this application's system settings page so the user can review
  /// or change granted permissions. Delegates to
  /// [ph.openAppSettings].
  Future<bool> openAppSettings() => ph.openAppSettings();

  static ph.PermissionStatus _aggregateStatus(
    Iterable<ph.PermissionStatus> statuses,
  ) {
    if (statuses.isEmpty) {
      return ph.PermissionStatus.denied;
    }
    return statuses.reduce(_worse);
  }

  static ph.PermissionStatus _worse(
    ph.PermissionStatus a,
    ph.PermissionStatus b,
  ) {
    return _severity(a) >= _severity(b) ? a : b;
  }

  static int _severity(ph.PermissionStatus status) {
    switch (status) {
      case ph.PermissionStatus.permanentlyDenied:
        return 4;
      case ph.PermissionStatus.restricted:
        return 3;
      case ph.PermissionStatus.denied:
        return 2;
      case ph.PermissionStatus.provisional:
        return 1;
      case ph.PermissionStatus.limited:
        return 1;
      case ph.PermissionStatus.granted:
        return 0;
    }
  }
}

import 'dart:typed_data';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../bluetooth/bluetooth_adapter_state.dart';
import '../core/connection_event.dart';
import '../core/connection_type.dart';
import '../core/printly_device.dart';
import 'printly_method_channel.dart';

/// The interface that platform-specific implementations of `printly` must
/// extend.
///
/// Platform implementations should extend this class rather than implement
/// it, so additions to the interface are not breaking changes for existing
/// subclasses.
abstract class PrintlyPlatform extends PlatformInterface {
  /// Constructs a [PrintlyPlatform].
  PrintlyPlatform() : super(token: _token);

  static final Object _token = Object();

  static PrintlyPlatform _instance = MethodChannelPrintly();

  /// The default instance of [PrintlyPlatform] to use.
  ///
  /// Defaults to [MethodChannelPrintly].
  static PrintlyPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [PrintlyPlatform] when they
  /// register themselves.
  static set instance(PrintlyPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Returns the native platform version string (e.g. `Android 14`, `iOS 17.2`).
  Future<String?> getPlatformVersion() {
    throw UnimplementedError('getPlatformVersion() has not been implemented.');
  }

  /// Returns the Android API level (`Build.VERSION.SDK_INT`). Only meaningful
  /// on Android; callers must guard with `Platform.isAndroid` before invoking.
  Future<int> getAndroidSdkInt() {
    throw UnimplementedError('getAndroidSdkInt() has not been implemented.');
  }

  /// A broadcast stream of native Bluetooth adapter state changes.
  ///
  /// Listening to this stream lazily initialises the native observer
  /// (Android [BluetoothAdapter] broadcast receiver or iOS
  /// `CBCentralManager`). On iOS this is also the moment the system
  /// permission prompt is triggered if Bluetooth usage has not yet been
  /// authorised.
  Stream<BluetoothAdapterState> get adapterState {
    throw UnimplementedError('adapterState has not been implemented.');
  }

  /// Opens the system Bluetooth settings page so the user can toggle the
  /// adapter on or off.
  ///
  /// On Android this dispatches `Settings.ACTION_BLUETOOTH_SETTINGS`; on
  /// iOS it opens the `App-Prefs:Bluetooth` URL scheme. Returns `true` if
  /// the settings page was successfully launched.
  Future<bool> openBluetoothSettings() {
    throw UnimplementedError(
      'openBluetoothSettings() has not been implemented.',
    );
  }

  /// Asks the native side to request that the user turn Bluetooth on, in
  /// place, without leaving the app.
  ///
  /// Returns whether the system request was actually **shown** — not
  /// whether the radio ended up on. This call does not wait for the user's
  /// decision; watch [adapterState] to observe the outcome. Returns `false`
  /// as a no-op when the radio is already on.
  Future<bool> requestEnableBluetooth() {
    throw UnimplementedError(
      'requestEnableBluetooth() has not been implemented.',
    );
  }

  /// Whether the OS location service currently gates Bluetooth scanning on
  /// this device.
  ///
  /// On Android below API 31 both Classic inquiry and BLE scanning depend on
  /// the location service — not just the location *permission* — and return
  /// no results at all (with no platform error) when it is off. From API 31
  /// printly declares `BLUETOOTH_SCAN` with `neverForLocation`, which removes
  /// the dependency entirely, so this always returns `true` there. iOS never
  /// depends on the location service for Bluetooth, so this always returns
  /// `true` on iOS too.
  Future<bool> isLocationServiceEnabled() {
    throw UnimplementedError(
      'isLocationServiceEnabled() has not been implemented.',
    );
  }

  /// Opens the system location settings page so the user can turn the
  /// location service on. Android only — returns `false` as a no-op on iOS,
  /// where this SDK does not touch CoreLocation.
  Future<bool> openLocationSettings() {
    throw UnimplementedError(
      'openLocationSettings() has not been implemented.',
    );
  }

  /// Asks the native side to start discovering devices of the given [types].
  ///
  /// The returned future completes as soon as the native scan has been
  /// requested — discovered devices arrive asynchronously on [scanResults].
  /// Callers should use [stopScan] or the Dart-side timeout managed by
  /// `ScanController` to stop the scan. Transport types not supported on the
  /// current platform (e.g. [ConnectionType.classic] on iOS) are silently
  /// dropped by the native side.
  Future<void> startScan({required Set<ConnectionType> types}) {
    throw UnimplementedError('startScan() has not been implemented.');
  }

  /// Cancels any in-progress native scan. Safe to call while no scan is
  /// running; native implementations must treat this as a no-op in that case.
  Future<void> stopScan() {
    throw UnimplementedError('stopScan() has not been implemented.');
  }

  /// Broadcast stream of discovered devices, one event per advertisement.
  ///
  /// The same physical device may be reported multiple times (for RSSI
  /// updates, Classic + BLE dual advertisements, etc.). De-duplication is
  /// the responsibility of the Dart-side scan controller, not the platform
  /// implementation.
  Stream<PrintlyDevice> get scanResults {
    throw UnimplementedError('scanResults has not been implemented.');
  }

  /// Asks the native side to open a link to [device] over [transport]. The
  /// future completes once the native stack reports the link as open, or
  /// rejects with a [PlatformException] if the attempt fails (permission
  /// denied, timeout, remote refusal, etc.).
  ///
  /// [transport] must be one of [PrintlyDevice.availableTransports] — the
  /// caller (`ConnectionController`) resolves which one before dispatching
  /// here. The **same** [transport] value must also be passed to the
  /// matching [disconnect] and [write] calls for this device: the native
  /// side keys a session by `type:address`, so a mismatched transport across
  /// the three calls silently misses the session instead of erroring.
  ///
  /// Per-device state transitions that happen after the future resolves —
  /// e.g. a remote disconnect, an auto-reconnect retry — arrive through
  /// [connectionEvents].
  Future<void> connect({
    required PrintlyDevice device,
    required ConnectionType transport,
    Duration? timeout,
  }) {
    throw UnimplementedError('connect() has not been implemented.');
  }

  /// Asks the native side to close the link to [device] over [transport].
  /// Safe to call when no link is open for [device]; native implementations
  /// must treat this as a no-op in that case.
  ///
  /// [transport] must match the value passed to the [connect] call that
  /// opened this session — see the note on [connect].
  Future<void> disconnect({
    required PrintlyDevice device,
    required ConnectionType transport,
  }) {
    throw UnimplementedError('disconnect() has not been implemented.');
  }

  /// Writes [bytes] to the open link to [device] over [transport].
  ///
  /// The future completes once the native stack has handed the payload to the
  /// transport (RFCOMM `OutputStream` flush, or the final GATT characteristic
  /// write acknowledgement), or rejects with a [PlatformException] when no link
  /// is open, the link is not yet ready for writes, or the transport fails.
  ///
  /// [transport] must match the value passed to the [connect] call that
  /// opened this session — see the note on [connect].
  Future<void> write({
    required PrintlyDevice device,
    required ConnectionType transport,
    required Uint8List bytes,
  }) {
    throw UnimplementedError('write() has not been implemented.');
  }

  /// Broadcast stream of native connection state changes. Each event carries
  /// the device it applies to and, on [ConnectionState.error], the reason
  /// reported by the transport. De-duplication and per-device fan-out is
  /// done in Dart.
  Stream<PrintlyConnectionEvent> get connectionEvents {
    throw UnimplementedError('connectionEvents has not been implemented.');
  }
}

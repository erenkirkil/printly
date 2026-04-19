import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../bluetooth/bluetooth_adapter_state.dart';
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
}

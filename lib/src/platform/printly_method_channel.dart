import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../bluetooth/bluetooth_adapter_state.dart';
import 'printly_platform_interface.dart';

/// Name of the method channel shared between Dart and native.
@visibleForTesting
const String kPrintlyMethodChannelName = 'printly';

/// Name of the event channel used to stream adapter state changes.
@visibleForTesting
const String kPrintlyAdapterStateEventChannelName = 'printly/adapter_state';

/// An implementation of [PrintlyPlatform] that uses method channels.
class MethodChannelPrintly extends PrintlyPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final MethodChannel methodChannel = const MethodChannel(
    kPrintlyMethodChannelName,
  );

  /// The event channel used to receive Bluetooth adapter state updates.
  @visibleForTesting
  final EventChannel adapterStateChannel = const EventChannel(
    kPrintlyAdapterStateEventChannelName,
  );

  Stream<BluetoothAdapterState>? _adapterStateStream;

  @override
  Future<String?> getPlatformVersion() async {
    final String? version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }

  @override
  Stream<BluetoothAdapterState> get adapterState {
    return _adapterStateStream ??= adapterStateChannel
        .receiveBroadcastStream()
        .map<BluetoothAdapterState>((dynamic event) {
          if (event is int) {
            return BluetoothAdapterState.fromCode(event);
          }
          return BluetoothAdapterState.unknown;
        });
  }

  @override
  Future<bool> openBluetoothSettings() async {
    final bool? opened = await methodChannel.invokeMethod<bool>(
      'openBluetoothSettings',
    );
    return opened ?? false;
  }
}

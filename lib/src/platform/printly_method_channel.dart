import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../bluetooth/bluetooth_adapter_state.dart';
import '../core/connection_event.dart';
import '../core/connection_type.dart';
import '../core/printly_device.dart';
import 'printly_platform_interface.dart';

/// Name of the method channel shared between Dart and native.
@visibleForTesting
const String kPrintlyMethodChannelName = 'printly';

/// Name of the event channel used to stream adapter state changes.
@visibleForTesting
const String kPrintlyAdapterStateEventChannelName = 'printly/adapter_state';

/// Name of the event channel used to stream scan results.
@visibleForTesting
const String kPrintlyScanResultsEventChannelName = 'printly/scan_results';

/// Name of the event channel used to stream per-device connection events.
@visibleForTesting
const String kPrintlyConnectionEventsChannelName = 'printly/connection_events';

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

  /// The event channel used to receive raw scan results.
  @visibleForTesting
  final EventChannel scanResultsChannel = const EventChannel(
    kPrintlyScanResultsEventChannelName,
  );

  /// The event channel used to receive per-device connection state changes.
  @visibleForTesting
  final EventChannel connectionEventsChannel = const EventChannel(
    kPrintlyConnectionEventsChannelName,
  );

  Stream<BluetoothAdapterState>? _adapterStateStream;
  Stream<PrintlyDevice>? _scanResultsStream;
  Stream<PrintlyConnectionEvent>? _connectionEventsStream;

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

  @override
  Future<void> startScan({required Set<ConnectionType> types}) async {
    await methodChannel.invokeMethod<void>('startScan', <String, Object?>{
      'types': types.map((ConnectionType t) => t.wireCode).toList(),
    });
  }

  @override
  Future<void> stopScan() async {
    await methodChannel.invokeMethod<void>('stopScan');
  }

  @override
  Stream<PrintlyDevice> get scanResults {
    return _scanResultsStream ??= scanResultsChannel
        .receiveBroadcastStream()
        .map<PrintlyDevice?>(_decodeScanEvent)
        .where((PrintlyDevice? d) => d != null)
        .cast<PrintlyDevice>();
  }

  static PrintlyDevice? _decodeScanEvent(dynamic event) {
    if (event is! Map) return null;
    final Object? address = event['address'];
    final Object? typeCode = event['type'];
    if (address is! String || typeCode is! int) return null;
    return PrintlyDevice(
      address: address,
      type: ConnectionType.fromWireCode(typeCode),
      name: event['name'] is String ? event['name'] as String : null,
      rssi: event['rssi'] is int ? event['rssi'] as int : null,
      isBonded: event['isBonded'] is bool ? event['isBonded'] as bool : false,
    );
  }

  @override
  Future<void> connect({
    required PrintlyDevice device,
    Duration? timeout,
  }) async {
    await methodChannel.invokeMethod<void>('connect', <String, Object?>{
      'device': device.toJson(),
      if (timeout != null) 'timeoutMs': timeout.inMilliseconds,
    });
  }

  @override
  Future<void> disconnect({required PrintlyDevice device}) async {
    await methodChannel.invokeMethod<void>('disconnect', <String, Object?>{
      'device': device.toJson(),
    });
  }

  @override
  Stream<PrintlyConnectionEvent> get connectionEvents {
    return _connectionEventsStream ??= connectionEventsChannel
        .receiveBroadcastStream()
        .map<PrintlyConnectionEvent?>(_decodeConnectionEvent)
        .where((PrintlyConnectionEvent? e) => e != null)
        .cast<PrintlyConnectionEvent>();
  }

  static PrintlyConnectionEvent? _decodeConnectionEvent(dynamic event) {
    if (event is! Map) return null;
    return PrintlyConnectionEvent.fromMap(event);
  }
}

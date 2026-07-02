import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../bluetooth/bluetooth_adapter_state.dart';
import '../core/connection_event.dart';
import '../core/connection_type.dart';
import '../core/printly_device.dart';
import '../core/printly_exception.dart';
import 'printly_platform_interface.dart';
import 'wire_protocol.dart';

/// Name of the method channel shared between Dart and native.
@visibleForTesting
const String kPrintlyMethodChannelName = WireProtocol.methodChannel;

/// Name of the event channel used to stream adapter state changes.
@visibleForTesting
const String kPrintlyAdapterStateEventChannelName =
    WireProtocol.adapterStateChannel;

/// Name of the event channel used to stream scan results.
@visibleForTesting
const String kPrintlyScanResultsEventChannelName =
    WireProtocol.scanResultsChannel;

/// Name of the event channel used to stream per-device connection events.
@visibleForTesting
const String kPrintlyConnectionEventsChannelName =
    WireProtocol.connectionEventsChannel;

/// Which call family a platform error came from — picks the
/// [PrintlyException] subtype when the error code alone is ambiguous.
enum _ErrorDomain { scan, connection, write }

/// An implementation of [PrintlyPlatform] that uses method channels.
class MethodChannelPrintly extends PrintlyPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final MethodChannel methodChannel = const MethodChannel(
    WireProtocol.methodChannel,
  );

  /// The event channel used to receive Bluetooth adapter state updates.
  @visibleForTesting
  final EventChannel adapterStateChannel = const EventChannel(
    WireProtocol.adapterStateChannel,
  );

  /// The event channel used to receive raw scan results.
  @visibleForTesting
  final EventChannel scanResultsChannel = const EventChannel(
    WireProtocol.scanResultsChannel,
  );

  /// The event channel used to receive per-device connection state changes.
  @visibleForTesting
  final EventChannel connectionEventsChannel = const EventChannel(
    WireProtocol.connectionEventsChannel,
  );

  Stream<BluetoothAdapterState>? _adapterStateStream;
  Stream<PrintlyDevice>? _scanResultsStream;
  Stream<PrintlyConnectionEvent>? _connectionEventsStream;

  @override
  Future<String?> getPlatformVersion() async {
    final String? version = await methodChannel.invokeMethod<String>(
      WireProtocol.mGetPlatformVersion,
    );
    return version;
  }

  @override
  Future<int> getAndroidSdkInt() async {
    final int? sdkInt = await methodChannel.invokeMethod<int>(
      WireProtocol.mGetAndroidSdkInt,
    );
    return sdkInt ?? 0;
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
      WireProtocol.mOpenBluetoothSettings,
    );
    return opened ?? false;
  }

  @override
  Future<void> startScan({required Set<ConnectionType> types}) {
    return _mapErrors(_ErrorDomain.scan, () async {
      await methodChannel
          .invokeMethod<void>(WireProtocol.mStartScan, <String, Object?>{
            WireProtocol.keyTypes: types
                .map((ConnectionType t) => t.wireCode)
                .toList(),
          });
    });
  }

  @override
  Future<void> stopScan() {
    return _mapErrors(_ErrorDomain.scan, () async {
      await methodChannel.invokeMethod<void>(WireProtocol.mStopScan);
    });
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
    final Object? address = event[WireProtocol.keyAddress];
    final Object? typeCode = event[WireProtocol.keyType];
    if (address is! String || typeCode is! int) return null;
    return PrintlyDevice(
      address: address,
      type: ConnectionType.fromWireCode(typeCode),
      name: event[WireProtocol.keyName] is String
          ? event[WireProtocol.keyName] as String
          : null,
      rssi: event[WireProtocol.keyRssi] is int
          ? event[WireProtocol.keyRssi] as int
          : null,
      isBonded: event[WireProtocol.keyIsBonded] is bool
          ? event[WireProtocol.keyIsBonded] as bool
          : false,
    );
  }

  @override
  Future<void> connect({required PrintlyDevice device, Duration? timeout}) {
    return _mapErrors(_ErrorDomain.connection, () async {
      await methodChannel
          .invokeMethod<void>(WireProtocol.mConnect, <String, Object?>{
            WireProtocol.keyDevice: device.toJson(),
            if (timeout != null)
              WireProtocol.keyTimeoutMs: timeout.inMilliseconds,
          });
    });
  }

  @override
  Future<void> disconnect({required PrintlyDevice device}) {
    return _mapErrors(_ErrorDomain.connection, () async {
      await methodChannel.invokeMethod<void>(
        WireProtocol.mDisconnect,
        <String, Object?>{WireProtocol.keyDevice: device.toJson()},
      );
    });
  }

  @override
  Future<void> write({
    required PrintlyDevice device,
    required Uint8List bytes,
  }) {
    return _mapErrors(_ErrorDomain.write, () async {
      await methodChannel.invokeMethod<void>(
        WireProtocol.mWrite,
        <String, Object?>{
          WireProtocol.keyDevice: device.toJson(),
          WireProtocol.keyBytes: bytes,
        },
      );
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

  /// Runs [action] and rethrows any [PlatformException] as the matching
  /// typed [PrintlyException], so consumers never have to parse
  /// platform-dependent code strings.
  static Future<void> _mapErrors(
    _ErrorDomain domain,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } on PlatformException catch (error) {
      throw _toPrintlyException(error, domain);
    }
  }

  static PrintlyException _toPrintlyException(
    PlatformException error,
    _ErrorDomain domain,
  ) {
    // The native sides put the generic family in `code` and the specific
    // reason in `message` (e.g. code `start_scan_failed`, message
    // `bluetooth_not_powered_on`), so a known message wins over the code.
    PrintlyErrorCode code = PrintlyErrorCode.fromWireName(error.message);
    if (code == PrintlyErrorCode.unknown) {
      code = PrintlyErrorCode.fromWireName(error.code);
    }
    final String message = error.message ?? error.code;

    switch (code) {
      case PrintlyErrorCode.permissionDenied:
        return PrintlyPermissionException(message);
      case PrintlyErrorCode.networkNotSupported:
      case PrintlyErrorCode.classicRequiresMfi:
      case PrintlyErrorCode.unsupportedPlatform:
        return PrintlyUnsupportedException(code, message);
      default:
        break;
    }

    return switch (domain) {
      _ErrorDomain.scan => PrintlyScanException(code, message),
      _ErrorDomain.connection => PrintlyConnectionException(code, message),
      _ErrorDomain.write => PrintlyWriteException(code, message),
    };
  }
}

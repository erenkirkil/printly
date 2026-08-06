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
  Future<bool> requestEnableBluetooth() async {
    // Unlike the void-returning calls above, this needs to both unwrap a
    // bool *and* map errors, so it cannot reuse [_mapErrors] (void-typed) —
    // the try/catch is inlined instead of adding a second, bool-returning
    // error-mapping helper for a single call site.
    try {
      final bool? shown = await methodChannel.invokeMethod<bool>(
        WireProtocol.mRequestEnableBluetooth,
      );
      return shown ?? false;
    } on PlatformException catch (error) {
      throw _toPrintlyException(error, _ErrorDomain.scan);
    }
  }

  @override
  Future<bool> isLocationServiceEnabled() async {
    // Same reasoning as [requestEnableBluetooth]: needs both a bool unwrap
    // and error mapping, so it does not go through the void-typed
    // [_mapErrors] helper.
    try {
      final bool? satisfied = await methodChannel.invokeMethod<bool>(
        WireProtocol.mIsLocationServiceEnabled,
      );
      return satisfied ?? true;
    } on PlatformException catch (error) {
      throw _toPrintlyException(error, _ErrorDomain.scan);
    }
  }

  @override
  Future<bool> openLocationSettings() async {
    try {
      final bool? opened = await methodChannel.invokeMethod<bool>(
        WireProtocol.mOpenLocationSettings,
      );
      return opened ?? false;
    } on PlatformException catch (error) {
      throw _toPrintlyException(error, _ErrorDomain.scan);
    }
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
    return PrintlyDevice.fromWireMap(event.cast<Object?, Object?>());
  }

  @override
  Future<void> connect({
    required PrintlyDevice device,
    required ConnectionType transport,
    Duration? timeout,
  }) {
    return _mapErrors(_ErrorDomain.connection, () async {
      await methodChannel
          .invokeMethod<void>(WireProtocol.mConnect, <String, Object?>{
            WireProtocol.keyDevice: _deviceWireMap(device, transport),
            if (timeout != null)
              WireProtocol.keyTimeoutMs: timeout.inMilliseconds,
          });
    });
  }

  @override
  Future<void> disconnect({
    required PrintlyDevice device,
    required ConnectionType transport,
  }) {
    return _mapErrors(_ErrorDomain.connection, () async {
      await methodChannel.invokeMethod<void>(
        WireProtocol.mDisconnect,
        <String, Object?>{
          WireProtocol.keyDevice: _deviceWireMap(device, transport),
        },
      );
    });
  }

  @override
  Future<void> write({
    required PrintlyDevice device,
    required ConnectionType transport,
    required Uint8List bytes,
  }) {
    return _mapErrors(_ErrorDomain.write, () async {
      await methodChannel
          .invokeMethod<void>(WireProtocol.mWrite, <String, Object?>{
            WireProtocol.keyDevice: _deviceWireMap(device, transport),
            WireProtocol.keyBytes: bytes,
          });
    });
  }

  /// Builds the native `keyDevice` payload for [device] over the given
  /// [transport]. The native side requires a single concrete transport per
  /// call (`keyType`) and keys its session by `type:address`, but
  /// [PrintlyDevice.availableTransports] may list more than one for a
  /// dual-mode radio — so [transport] must be the *same* value across the
  /// [connect]/[disconnect]/[write] calls for one session. Passing a
  /// different transport than the one used to open the session does not
  /// error; it silently misses the session on the native side. The caller
  /// (`ConnectionController`) is responsible for resolving and remembering
  /// that one value; this helper only assembles the wire map.
  static Map<String, Object?> _deviceWireMap(
    PrintlyDevice device,
    ConnectionType transport,
  ) => <String, Object?>{
    WireProtocol.keyAddress: device.address,
    WireProtocol.keyType: transport.wireCode,
    if (device.name != null) WireProtocol.keyName: device.name,
  };

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

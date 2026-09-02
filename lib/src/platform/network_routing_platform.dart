import 'dart:async';
import 'dart:typed_data';

import '../bluetooth/bluetooth_adapter_state.dart';
import '../core/connection_event.dart';
import '../core/connection_type.dart';
import '../core/printly_device.dart';
import '../network/tcp_printer_transport.dart';
import 'printly_platform_interface.dart';

/// Wraps another [PrintlyPlatform] and routes network-transport calls to a
/// pure-Dart [TcpPrinterTransport], delegating every Bluetooth call to the
/// inner platform. [connectionEvents] is the merge of both sources, so the
/// connection controller above sees one unified stream and needs no
/// network-specific branch.
///
/// This decorator lives only inside the `Printly` facade; it is never
/// installed as `PrintlyPlatform.instance`, so the platform-interface token
/// guard and a consumer's own fake are unaffected.
class NetworkRoutingPlatform extends PrintlyPlatform {
  /// Wraps [inner] (usually `PrintlyPlatform.instance`), optionally with a
  /// supplied [tcp] transport (tests inject one; production creates the
  /// default).
  NetworkRoutingPlatform({
    required PrintlyPlatform inner,
    TcpPrinterTransport? tcp,
  }) : _inner = inner,
       _tcp = tcp ?? TcpPrinterTransport() {
    // Sources are subscribed lazily, on the first listener, and dropped again
    // with the last one. Subscribing in the constructor would make merely
    // constructing the decorator listen to the native connection-event
    // channel, which is what triggers the iOS Bluetooth permission prompt —
    // an app that only prints over TCP must not be asked for Bluetooth.
    _merged = StreamController<PrintlyConnectionEvent>.broadcast(
      onListen: _subscribeSources,
      onCancel: _unsubscribeSources,
    );
  }

  final PrintlyPlatform _inner;
  final TcpPrinterTransport _tcp;
  late final StreamController<PrintlyConnectionEvent> _merged;
  StreamSubscription<PrintlyConnectionEvent>? _innerSub;
  StreamSubscription<PrintlyConnectionEvent>? _tcpSub;

  void _subscribeSources() {
    // Errors are forwarded, not just data. The native connection-event
    // channel can push a PlatformException onto the stream, and
    // `ConnectionController` installs an onError handler that deliberately
    // swallows it. A data-only merge would leave that handler unreachable and
    // turn every source error into an uncaught zone error — a decorator must
    // not change what escapes the stream it wraps.
    _innerSub = _inner.connectionEvents.listen(
      _merged.add,
      onError: _merged.addError,
    );
    _tcpSub = _tcp.events.listen(_merged.add, onError: _merged.addError);
  }

  Future<void> _unsubscribeSources() async {
    final StreamSubscription<PrintlyConnectionEvent>? innerSub = _innerSub;
    final StreamSubscription<PrintlyConnectionEvent>? tcpSub = _tcpSub;
    // Cleared before awaiting: a re-listen that arrives while the two cancels
    // are still in flight would otherwise overwrite the fresh subscriptions
    // with nulls when this resumes, leaving the merged stream silent.
    _innerSub = null;
    _tcpSub = null;
    await innerSub?.cancel();
    await tcpSub?.cancel();
  }

  @override
  Stream<PrintlyConnectionEvent> get connectionEvents => _merged.stream;

  /// Routes [ConnectionType.network] to the TCP transport and everything else
  /// to the inner platform.
  ///
  /// Both routes report the outcome the same way — on [connectionEvents], not
  /// by rejecting — so `ConnectionController` resolves a network attempt
  /// through exactly the path it uses for Bluetooth. See
  /// [TcpPrinterTransport.connect] for why the network side does not also
  /// throw.
  @override
  Future<void> connect({
    required PrintlyDevice device,
    required ConnectionType transport,
    Duration? timeout,
  }) {
    if (transport == ConnectionType.network) {
      return _tcp.connect(device, timeout: timeout);
    }
    return _inner.connect(
      device: device,
      transport: transport,
      timeout: timeout,
    );
  }

  /// Routes [ConnectionType.network] to the TCP transport and everything else
  /// to the inner platform. Either route emits a terminal `disconnected`
  /// event even when it has no session to close, which is what keeps the
  /// controller above from waiting forever in `disconnecting`.
  @override
  Future<void> disconnect({
    required PrintlyDevice device,
    required ConnectionType transport,
  }) {
    if (transport == ConnectionType.network) {
      return _tcp.disconnect(device);
    }
    return _inner.disconnect(device: device, transport: transport);
  }

  @override
  Future<void> write({
    required PrintlyDevice device,
    required ConnectionType transport,
    required Uint8List bytes,
  }) {
    if (transport == ConnectionType.network) {
      return _tcp.write(device, bytes);
    }
    return _inner.write(device: device, transport: transport, bytes: bytes);
  }

  // ---- Everything else delegates straight to inner. ----

  @override
  Future<String?> getPlatformVersion() => _inner.getPlatformVersion();

  @override
  Future<int> getAndroidSdkInt() => _inner.getAndroidSdkInt();

  @override
  Stream<BluetoothAdapterState> get adapterState => _inner.adapterState;

  @override
  Future<bool> openBluetoothSettings() => _inner.openBluetoothSettings();

  @override
  Future<bool> requestEnableBluetooth() => _inner.requestEnableBluetooth();

  @override
  Future<bool> isLocationServiceEnabled() => _inner.isLocationServiceEnabled();

  @override
  Future<bool> isLocationRequired() => _inner.isLocationRequired();

  @override
  Future<bool> openLocationSettings() => _inner.openLocationSettings();

  @override
  Future<void> startScan({
    required Set<ConnectionType> types,
    bool includeUnnamed = false,
  }) => _inner.startScan(types: types, includeUnnamed: includeUnnamed);

  @override
  Future<void> stopScan() => _inner.stopScan();

  @override
  Stream<PrintlyDevice> get scanResults => _inner.scanResults;

  /// Releases the TCP transport and the merged event stream. The inner
  /// platform is deliberately left alone — it is a process-wide singleton
  /// this decorator borrows, not something it owns.
  Future<void> dispose() async {
    await _unsubscribeSources();
    await _tcp.dispose();
    await _merged.close();
  }
}

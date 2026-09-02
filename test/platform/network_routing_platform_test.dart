import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:printly/printly.dart';
import 'package:printly/src/bluetooth/connection_controller.dart';
import 'package:printly/src/network/tcp_printer_transport.dart';
import 'package:printly/src/platform/network_routing_platform.dart';

class _InnerFake extends PrintlyPlatform with MockPlatformInterfaceMixin {
  final StreamController<PrintlyConnectionEvent> events =
      StreamController<PrintlyConnectionEvent>.broadcast();
  int connectCalls = 0;
  int writeCalls = 0;
  int disconnectCalls = 0;
  int startScanCalls = 0;

  @override
  Stream<PrintlyConnectionEvent> get connectionEvents => events.stream;

  @override
  Future<void> connect({
    required PrintlyDevice device,
    required ConnectionType transport,
    Duration? timeout,
  }) async {
    connectCalls++;
  }

  @override
  Future<void> disconnect({
    required PrintlyDevice device,
    required ConnectionType transport,
  }) async {
    disconnectCalls++;
  }

  @override
  Future<void> write({
    required PrintlyDevice device,
    required ConnectionType transport,
    required Uint8List bytes,
  }) async {
    writeCalls++;
  }

  @override
  Future<void> startScan({
    required Set<ConnectionType> types,
    bool includeUnnamed = false,
  }) async {
    startScanCalls++;
  }

  Future<void> close() => events.close();
}

final PrintlyDevice bleDevice = PrintlyDevice(
  address: 'AA:BB',
  availableTransports: const <ConnectionType>{ConnectionType.ble},
  name: 'ble',
);

void main() {
  late _InnerFake inner;
  late NetworkRoutingPlatform platform;

  setUp(() {
    inner = _InnerFake();
    platform = NetworkRoutingPlatform(inner: inner);
  });

  tearDown(() async {
    await platform.dispose();
    await inner.close();
  });

  test('ble connect delegates to inner, not TCP', () async {
    await platform.connect(device: bleDevice, transport: ConnectionType.ble);
    expect(inner.connectCalls, 1);
  });

  test('network connect goes to TCP, not inner', () async {
    final ServerSocket server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final PrintlyDevice net = PrintlyDevice.network(
      host: '127.0.0.1',
      port: server.port,
    );

    await platform.connect(device: net, transport: ConnectionType.network);
    expect(inner.connectCalls, 0);

    await platform.disconnect(device: net, transport: ConnectionType.network);
    expect(inner.disconnectCalls, 0);
    await server.close();
  });

  test('network write goes to TCP, ble write to inner', () async {
    final ServerSocket server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((Socket s) => unawaited(s.drain<void>()));
    final PrintlyDevice net = PrintlyDevice.network(
      host: '127.0.0.1',
      port: server.port,
    );

    await platform.connect(device: net, transport: ConnectionType.network);
    await platform.write(
      device: net,
      transport: ConnectionType.network,
      bytes: Uint8List.fromList(<int>[0x41]),
    );
    expect(inner.writeCalls, 0);

    await platform.write(
      device: bleDevice,
      transport: ConnectionType.ble,
      bytes: Uint8List.fromList(<int>[0x41]),
    );
    expect(inner.writeCalls, 1);
    await server.close();
  });

  test('connectionEvents merges inner and TCP sources', () async {
    final ServerSocket server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final PrintlyDevice net = PrintlyDevice.network(
      host: '127.0.0.1',
      port: server.port,
    );

    final List<ConnectionState> states = <ConnectionState>[];
    final StreamSubscription<PrintlyConnectionEvent> sub = platform
        .connectionEvents
        .listen((PrintlyConnectionEvent e) => states.add(e.state));

    inner.events.add(
      PrintlyConnectionEvent(
        device: bleDevice,
        state: ConnectionState.connecting,
      ),
    );
    await platform.connect(device: net, transport: ConnectionType.network);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(states, contains(ConnectionState.connecting)); // from inner
    expect(states, contains(ConnectionState.connected)); // from TCP

    await sub.cancel();
    await server.close();
  });

  test('an error on the inner stream reaches the merged stream', () async {
    // Regression: a data-only merge dropped source errors, so
    // ConnectionController's deliberate onError swallow became dead code and
    // the error escaped as an uncaught zone error instead.
    final List<Object> errors = <Object>[];
    final StreamSubscription<PrintlyConnectionEvent> sub = platform
        .connectionEvents
        .listen((PrintlyConnectionEvent _) {}, onError: errors.add);

    inner.events.addError(StateError('boom'));
    await Future<void>.delayed(Duration.zero);

    expect(errors, hasLength(1));
    expect(errors.single, isStateError);

    await sub.cancel();
  });

  test('non-connection methods delegate to inner', () async {
    await platform.startScan(types: const <ConnectionType>{ConnectionType.ble});
    expect(inner.startScanCalls, 1);
  });

  group('ConnectionController over the network route', () {
    // The decorator's whole point is that the controller cannot tell a network
    // link from a Bluetooth one. These pair the TCP path against the contract
    // the native coordinators actually implement, which is what the controller
    // was written against — a unit test of the transport alone cannot see the
    // damage a deviation does one layer up.
    late TcpPrinterTransport tcp;
    late NetworkRoutingPlatform routed;
    late ConnectionController controller;

    void build(SocketConnector connector) {
      tcp = TcpPrinterTransport(connector: connector);
      routed = NetworkRoutingPlatform(inner: inner, tcp: tcp);
      controller = ConnectionController(platform: routed);
    }

    tearDown(() async {
      await controller.dispose();
      await routed.dispose();
    });

    test('a retry issued from the catch block of a failed connect '
        'is not rejected by the failure it is retrying', () async {
      // The failure must be reported once. Reported twice — a throw plus an
      // event — the throw resolves the first attempt and the event arrives
      // afterwards, by which time the caller's catch block has already started
      // attempt two: the stale error then rejects the retry while its socket
      // is open, telling the caller the connect failed as `stateOf` reports
      // `connected`.
      final ServerSocket server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      server.listen((Socket s) => unawaited(s.drain<void>()));
      int dials = 0;
      build((String host, int port, {Duration? timeout}) async {
        dials++;
        if (dials == 1) {
          throw const SocketException('Connection refused');
        }
        return Socket.connect(host, port, timeout: timeout);
      });
      final PrintlyDevice net = PrintlyDevice.network(
        host: '127.0.0.1',
        port: server.port,
      );

      Object? firstError;
      Object? retryError;
      try {
        await controller.connect(net);
      } catch (error) {
        firstError = error;
        try {
          await controller.connect(net);
        } catch (error) {
          retryError = error;
        }
      }

      expect(firstError, isA<PrintlyConnectionException>());
      expect(retryError, isNull, reason: 'the retry opened a live socket');
      expect(dials, 2);
      expect(controller.stateOf(net), ConnectionState.connected);
      expect(controller.activeDevice?.address, net.address);

      await controller.disconnect(device: net);
      await server.close();
    });

    test('a single failed connect reports error exactly once', () async {
      // Two `error` states for one failure make every error-driven UI fire
      // twice: a snackbar shown twice, a retry loop counting one failure as
      // two.
      build(
        (String host, int port, {Duration? timeout}) async =>
            throw const SocketException('Connection refused'),
      );
      final PrintlyDevice net = PrintlyDevice.network(
        host: '127.0.0.1',
        port: 9100,
      );
      final List<ConnectionState> states = <ConnectionState>[];
      final StreamSubscription<ConnectionState> sub = controller
          .connectionStateOf(net)
          .listen(states.add);

      await expectLater(
        controller.connect(net),
        throwsA(
          isA<PrintlyConnectionException>().having(
            (PrintlyConnectionException e) => e.code,
            'code',
            // The reason the transport emits leads with the wire code and
            // appends detail, so it resolves through the controller's
            // `unknown` fallback. README promises this code for a refused
            // dial (and for a denied iOS local-network permission).
            PrintlyErrorCode.connectFailed,
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        states.where((ConnectionState s) => s == ConnectionState.error),
        hasLength(1),
      );
      await sub.cancel();
    });

    test(
      'a connect timeout surfaces as connectTimeout, not connectFailed',
      () async {
        // The transport's deadline is deliberately shorter than the
        // controller's guard timer (kNetworkTimeoutHeadroom), so the reason
        // reaching the caller is the transport's — and it must be the bare wire
        // reason, or the controller's `unknown` fallback would relabel a stalled
        // printer as a refused one.
        final Completer<Socket> never = Completer<Socket>();
        build((String host, int port, {Duration? timeout}) => never.future);
        final PrintlyDevice net = PrintlyDevice.network(
          host: '127.0.0.1',
          port: 9100,
        );

        await expectLater(
          controller.connect(net, timeout: const Duration(milliseconds: 300)),
          throwsA(
            isA<PrintlyConnectionException>().having(
              (PrintlyConnectionException e) => e.code,
              'code',
              PrintlyErrorCode.connectTimeout,
            ),
          ),
        );
      },
    );

    test('disconnect after a failed connect settles at disconnected '
        'instead of wedging in disconnecting', () async {
      // Native parity check: both coordinators emit `disconnected` when asked
      // to close a session they do not have, because the controller emits
      // `disconnecting` locally and waits for the transport's terminal event.
      // A failed connect leaves an `error` state, so `disconnect()` does reach
      // the transport — and a silent no-op there strands the device.
      build(
        (String host, int port, {Duration? timeout}) async =>
            throw const SocketException('Connection refused'),
      );
      final PrintlyDevice net = PrintlyDevice.network(
        host: '127.0.0.1',
        port: 9100,
      );

      await expectLater(
        controller.connect(net),
        throwsA(isA<PrintlyConnectionException>()),
      );
      expect(controller.stateOf(net), ConnectionState.error);

      final Future<ConnectionState> settled = controller
          .connectionStateOf(net)
          .firstWhere((ConnectionState s) => s == ConnectionState.disconnected)
          .timeout(const Duration(seconds: 2));
      await controller.disconnect(device: net);

      expect(await settled, ConnectionState.disconnected);
      expect(controller.stateOf(net), ConnectionState.disconnected);
    });
  });
}

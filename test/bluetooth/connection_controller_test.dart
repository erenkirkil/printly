import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:printly/printly.dart';
import 'package:printly/src/bluetooth/connection_controller.dart';
import 'package:printly/src/platform/printly_platform_interface.dart';

class _FakePlatform extends PrintlyPlatform with MockPlatformInterfaceMixin {
  final StreamController<PrintlyConnectionEvent> _events =
      StreamController<PrintlyConnectionEvent>.broadcast();

  int connectCalls = 0;
  int disconnectCalls = 0;
  final List<PrintlyDevice> connectDevices = <PrintlyDevice>[];
  final List<PrintlyDevice> disconnectDevices = <PrintlyDevice>[];
  Completer<void>? connectCompleter;
  Object? connectError;

  @override
  Stream<PrintlyConnectionEvent> get connectionEvents => _events.stream;

  @override
  Future<void> connect({
    required PrintlyDevice device,
    Duration? timeout,
  }) async {
    connectCalls++;
    connectDevices.add(device);
    if (connectCompleter != null) await connectCompleter!.future;
    if (connectError != null) throw connectError!;
  }

  @override
  Future<void> disconnect({required PrintlyDevice device}) async {
    disconnectCalls++;
    disconnectDevices.add(device);
  }

  @override
  Stream<PrintlyDevice> get scanResults => const Stream<PrintlyDevice>.empty();

  @override
  Future<void> startScan({required Set<ConnectionType> types}) async {}

  @override
  Future<void> stopScan() async {}

  void emit(PrintlyConnectionEvent event) => _events.add(event);

  Future<void> close() async {
    await _events.close();
  }
}

final PrintlyDevice deviceA = PrintlyDevice(
  address: 'AA:AA',
  availableTransports: <ConnectionType>{ConnectionType.ble},
  name: 'A',
);
final PrintlyDevice deviceB = PrintlyDevice(
  address: 'BB:BB',
  availableTransports: <ConnectionType>{ConnectionType.ble},
  name: 'B',
);

void main() {
  late _FakePlatform platform;
  late ConnectionController controller;

  setUp(() {
    platform = _FakePlatform();
    controller = ConnectionController(platform: platform);
  });

  tearDown(() async {
    await controller.dispose();
    await platform.close();
  });

  group('re-entrancy', () {
    test('concurrent connect() calls share one native request', () async {
      platform.connectCompleter = Completer<void>();
      final Future<void> first = controller.connect(deviceA);
      final Future<void> second = controller.connect(deviceA);
      expect(identical(first, second), isTrue);

      platform.connectCompleter!.complete();
      await Future<void>.delayed(Duration.zero);
      platform.emit(
        PrintlyConnectionEvent(
          device: deviceA,
          state: ConnectionState.connected,
        ),
      );
      await Future.wait(<Future<void>>[first, second]);
      expect(platform.connectCalls, 1);
    });

    test('connect() while already connected is a no-op', () async {
      final Future<void> f = controller.connect(deviceA);
      await Future<void>.delayed(Duration.zero);
      platform.emit(
        PrintlyConnectionEvent(
          device: deviceA,
          state: ConnectionState.connected,
        ),
      );
      await f;
      expect(controller.stateOf(deviceA), ConnectionState.connected);

      await controller.connect(deviceA);
      expect(platform.connectCalls, 1);
    });

    test('switching to a new device disconnects the previous first', () async {
      final Future<void> fa = controller.connect(deviceA);
      await Future<void>.delayed(Duration.zero);
      platform.emit(
        PrintlyConnectionEvent(
          device: deviceA,
          state: ConnectionState.connected,
        ),
      );
      await fa;
      expect(controller.activeDevice, deviceA);

      final Future<void> fb = controller.connect(deviceB);
      await Future<void>.delayed(Duration.zero);
      platform.emit(
        PrintlyConnectionEvent(
          device: deviceB,
          state: ConnectionState.connected,
        ),
      );
      await fb;
      expect(platform.disconnectDevices, <PrintlyDevice>[deviceA]);
      expect(platform.connectDevices, <PrintlyDevice>[deviceA, deviceB]);
    });

    test('concurrent disconnect() calls share one native request', () async {
      final Future<void> f = controller.connect(deviceA);
      await Future<void>.delayed(Duration.zero);
      platform.emit(
        PrintlyConnectionEvent(
          device: deviceA,
          state: ConnectionState.connected,
        ),
      );
      await f;

      final Future<void> a = controller.disconnect(device: deviceA);
      final Future<void> b = controller.disconnect(device: deviceA);
      expect(identical(a, b), isTrue);
      await Future.wait(<Future<void>>[a, b]);
      expect(platform.disconnectCalls, 1);
    });

    test('disconnect() while nothing is open is a no-op', () async {
      await controller.disconnect();
      expect(platform.disconnectCalls, 0);
    });
  });

  group('state fan-out', () {
    test(
      'per-device stream is seeded with disconnected and receives events',
      () async {
        final List<ConnectionState> received = <ConnectionState>[];
        final subscription = controller
            .connectionStateOf(deviceA)
            .listen(received.add);
        await Future<void>.delayed(Duration.zero);
        expect(received, <ConnectionState>[ConnectionState.disconnected]);

        platform.emit(
          PrintlyConnectionEvent(
            device: deviceA,
            state: ConnectionState.connecting,
          ),
        );
        platform.emit(
          PrintlyConnectionEvent(
            device: deviceA,
            state: ConnectionState.connected,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(received, <ConnectionState>[
          ConnectionState.disconnected,
          ConnectionState.connecting,
          ConnectionState.connected,
        ]);
        await subscription.cancel();
      },
    );

    test(
      'activeDevice updates on connected/disconnected transitions',
      () async {
        final List<PrintlyDevice?> devices = <PrintlyDevice?>[];
        final subscription = controller.activeDeviceStream.listen(devices.add);

        platform.emit(
          PrintlyConnectionEvent(
            device: deviceA,
            state: ConnectionState.connected,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        platform.emit(
          PrintlyConnectionEvent(
            device: deviceA,
            state: ConnectionState.disconnected,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(devices, <PrintlyDevice?>[null, deviceA, null]);
        await subscription.cancel();
      },
    );

    test(
      'error event surfaces the failureReason via lastFailureReasonOf',
      () async {
        platform.emit(
          PrintlyConnectionEvent(
            device: deviceA,
            state: ConnectionState.error,
            failureReason: 'socket timeout',
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(controller.stateOf(deviceA), ConnectionState.error);
        expect(controller.lastFailureReasonOf(deviceA), 'socket timeout');
      },
    );

    test(
      'connect() failure records the reason and flips state to error',
      () async {
        platform.connectError = Exception('refused');
        await expectLater(
          controller.connect(deviceA),
          throwsA(isA<Exception>()),
        );
        expect(controller.stateOf(deviceA), ConnectionState.error);
        expect(controller.lastFailureReasonOf(deviceA), contains('refused'));
      },
    );
  });

  group('connect resolution', () {
    test('future resolves only when the connected event arrives', () async {
      final Future<void> future = controller.connect(deviceA);
      bool done = false;
      unawaited(future.then((_) => done = true));
      await Future<void>.delayed(Duration.zero);
      // Native request dispatched, but no terminal event yet.
      expect(done, isFalse);

      platform.emit(
        PrintlyConnectionEvent(
          device: deviceA,
          state: ConnectionState.connected,
        ),
      );
      await future;
      expect(done, isTrue);
    });

    test('future fails when an error event arrives', () async {
      final Future<void> future = controller.connect(deviceA);
      await Future<void>.delayed(Duration.zero);
      platform.emit(
        PrintlyConnectionEvent(
          device: deviceA,
          state: ConnectionState.error,
          failureReason: 'refused',
        ),
      );
      await expectLater(future, throwsA(isA<Exception>()));
      expect(controller.stateOf(deviceA), ConnectionState.error);
    });

    test('future fails on a timeout when nothing terminal arrives', () async {
      final Future<void> future = controller.connect(
        deviceA,
        timeout: const Duration(milliseconds: 30),
      );
      await expectLater(future, throwsA(isA<TimeoutException>()));
      expect(controller.stateOf(deviceA), ConnectionState.error);
    });
  });

  group('disconnect-then-connect race', () {
    Future<void> establish(PrintlyDevice device) async {
      final Future<void> f = controller.connect(device);
      await Future<void>.delayed(Duration.zero);
      platform.emit(
        PrintlyConnectionEvent(
          device: device,
          state: ConnectionState.connected,
        ),
      );
      await f;
    }

    test('stale disconnected event from the old link does not reject a fresh '
        'connect for the same device', () async {
      await establish(deviceA);

      // Fire-and-forget "reconnect" gesture: disconnect + connect without
      // awaiting in between.
      unawaited(controller.disconnect(device: deviceA));
      final Future<void> reconnect = controller.connect(deviceA);
      await Future<void>.delayed(Duration.zero);

      // The OLD link's terminal event lands after the new attempt started…
      platform.emit(
        PrintlyConnectionEvent(
          device: deviceA,
          state: ConnectionState.disconnected,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      // …and must neither reject the pending future nor flip the state.
      expect(controller.stateOf(deviceA), ConnectionState.connecting);

      platform.emit(
        PrintlyConnectionEvent(
          device: deviceA,
          state: ConnectionState.connected,
        ),
      );
      await reconnect;
      expect(controller.stateOf(deviceA), ConnectionState.connected);
    });

    test('only the first disconnected event is swallowed', () async {
      await establish(deviceA);

      unawaited(controller.disconnect(device: deviceA));
      final Future<void> reconnect = controller.connect(deviceA);
      await Future<void>.delayed(Duration.zero);

      // Old link's terminal event (swallowed)…
      platform.emit(
        PrintlyConnectionEvent(
          device: deviceA,
          state: ConnectionState.disconnected,
        ),
      );
      // …then the NEW attempt genuinely fails with a disconnect.
      platform.emit(
        PrintlyConnectionEvent(
          device: deviceA,
          state: ConnectionState.disconnected,
        ),
      );
      await expectLater(reconnect, throwsA(isA<Exception>()));
      expect(controller.stateOf(deviceA), ConnectionState.disconnected);
    });

    test(
      'a plain disconnected event still rejects a pending connect',
      () async {
        final Future<void> future = controller.connect(deviceA);
        await Future<void>.delayed(Duration.zero);
        platform.emit(
          PrintlyConnectionEvent(
            device: deviceA,
            state: ConnectionState.disconnected,
          ),
        );
        await expectLater(future, throwsA(isA<Exception>()));
      },
    );
  });
}

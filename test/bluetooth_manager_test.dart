import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:printly/printly.dart';
import 'package:printly/src/bluetooth/bluetooth_manager.dart';
import 'package:printly/src/platform/printly_platform_interface.dart';

class _FakePlatform extends PrintlyPlatform with MockPlatformInterfaceMixin {
  _FakePlatform();

  final StreamController<BluetoothAdapterState> controller =
      StreamController<BluetoothAdapterState>.broadcast();

  @override
  Stream<BluetoothAdapterState> get adapterState => controller.stream;

  @override
  Future<String?> getPlatformVersion() async => 'fake';

  @override
  Future<bool> openBluetoothSettings() async => true;

  @override
  Future<void> startScan({required Set<ConnectionType> types}) async {}

  @override
  Future<void> stopScan() async {}

  @override
  Stream<PrintlyDevice> get scanResults => const Stream<PrintlyDevice>.empty();

  @override
  Future<void> connect({
    required PrintlyDevice device,
    Duration? timeout,
  }) async {}

  @override
  Future<void> disconnect({required PrintlyDevice device}) async {}

  @override
  Stream<PrintlyConnectionEvent> get connectionEvents =>
      const Stream<PrintlyConnectionEvent>.empty();
}

void main() {
  late _FakePlatform platform;
  late BluetoothManager manager;

  setUp(() {
    platform = _FakePlatform();
    manager = BluetoothManager(platform: platform);
  });

  tearDown(() async {
    await manager.dispose();
    await platform.controller.close();
  });

  test('currentState defaults to unknown before any event arrives', () {
    expect(manager.currentState, BluetoothAdapterState.unknown);
    expect(manager.isBluetoothAvailable, isFalse);
  });

  test('caches the latest state emitted by the platform', () async {
    final Stream<BluetoothAdapterState> stream = manager.stream;
    final List<BluetoothAdapterState> received = <BluetoothAdapterState>[];
    final StreamSubscription<BluetoothAdapterState> sub = stream.listen(
      received.add,
    );

    platform.controller.add(BluetoothAdapterState.poweredOff);
    platform.controller.add(BluetoothAdapterState.poweredOn);
    await Future<void>.delayed(Duration.zero);

    expect(received, <BluetoothAdapterState>[
      BluetoothAdapterState.poweredOff,
      BluetoothAdapterState.poweredOn,
    ]);
    expect(manager.currentState, BluetoothAdapterState.poweredOn);
    expect(manager.isBluetoothAvailable, isTrue);

    await sub.cancel();
  });

  test('supports multiple concurrent subscribers', () async {
    final Stream<BluetoothAdapterState> stream = manager.stream;
    final List<BluetoothAdapterState> a = <BluetoothAdapterState>[];
    final List<BluetoothAdapterState> b = <BluetoothAdapterState>[];
    final StreamSubscription<BluetoothAdapterState> subA = stream.listen(a.add);
    final StreamSubscription<BluetoothAdapterState> subB = stream.listen(b.add);

    platform.controller.add(BluetoothAdapterState.poweredOn);
    await Future<void>.delayed(Duration.zero);

    expect(a, <BluetoothAdapterState>[BluetoothAdapterState.poweredOn]);
    expect(b, <BluetoothAdapterState>[BluetoothAdapterState.poweredOn]);

    await subA.cancel();
    await subB.cancel();
  });
}

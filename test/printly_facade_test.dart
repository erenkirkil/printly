import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:printly/printly.dart';
import 'package:printly/src/platform/printly_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePlatform extends PrintlyPlatform with MockPlatformInterfaceMixin {
  final StreamController<PrintlyConnectionEvent> events =
      StreamController<PrintlyConnectionEvent>.broadcast();
  final StreamController<BluetoothAdapterState> adapter =
      StreamController<BluetoothAdapterState>.broadcast();

  int connectCalls = 0;
  final List<PrintlyDevice> connectDevices = <PrintlyDevice>[];

  @override
  Stream<PrintlyConnectionEvent> get connectionEvents => events.stream;

  @override
  Stream<BluetoothAdapterState> get adapterState => adapter.stream;

  @override
  Future<void> connect({
    required PrintlyDevice device,
    Duration? timeout,
  }) async {
    connectCalls++;
    connectDevices.add(device);
  }

  @override
  Future<void> disconnect({required PrintlyDevice device}) async {}

  @override
  Stream<PrintlyDevice> get scanResults => const Stream<PrintlyDevice>.empty();

  @override
  Future<void> startScan({required Set<ConnectionType> types}) async {}

  @override
  Future<void> stopScan() async {}

  Future<void> close() async {
    await events.close();
    await adapter.close();
  }
}

const PrintlyDevice device = PrintlyDevice(
  address: 'AA:BB:CC:DD:EE:FF',
  type: ConnectionType.classic,
  name: 'PTP-II',
);

const String _deviceKey = 'printly.last_connected_device';
const String _autoReconnectKey = 'printly.auto_reconnect_enabled';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakePlatform platform;

  setUp(() {
    platform = _FakePlatform();
    PrintlyPlatform.instance = platform;
  });

  tearDown(() async {
    await platform.close();
  });

  /// Drives a connect through the facade to the `connected` state.
  Future<void> establish(Printly printly) async {
    final Future<void> f = printly.connect(device);
    await Future<void>.delayed(Duration.zero);
    platform.events.add(
      const PrintlyConnectionEvent(
        device: device,
        state: ConnectionState.connected,
      ),
    );
    await f;
  }

  group('last-device persistence', () {
    test('a plain connect() persists the device without any store-touching '
        'API being called first (regression)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final Printly printly = Printly.forTesting();

      await establish(printly);
      await pumpEventQueue();

      expect(printly.lastConnectedDevice, device);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_deviceKey);
      expect(raw, isNotNull);
      expect(
        PrintlyDevice.fromJson(
          (json.decode(raw!) as Map).cast<String, Object?>(),
        ),
        device,
      );
    });

    test('reconnectLastDevice() works on a fresh launch after a plain '
        'connect in the previous session', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _deviceKey: json.encode(device.toJson()),
      });
      final Printly printly = Printly.forTesting();

      final Future<bool> result = printly.reconnectLastDevice();
      await pumpEventQueue();
      platform.events.add(
        const PrintlyConnectionEvent(
          device: device,
          state: ConnectionState.connected,
        ),
      );
      expect(await result, isTrue);
      expect(platform.connectDevices, <PrintlyDevice>[device]);
    });

    test('a device connected in this session is not clobbered by the '
        'stale persisted one when the store opens later', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _deviceKey: json.encode(
          const PrintlyDevice(
            address: '11:22:33:44:55:66',
            type: ConnectionType.ble,
            name: 'OLD',
          ).toJson(),
        ),
      });
      final Printly printly = Printly.forTesting();

      await establish(printly);
      await pumpEventQueue();

      expect(printly.lastConnectedDevice, device);
      await printly.loadLastConnectedDevice();
      expect(printly.lastConnectedDevice, device);
    });
  });

  group('auto-reconnect restore', () {
    test('a persisted auto-reconnect flag re-arms the adapter listener on '
        'the next launch (regression)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _autoReconnectKey: true,
        _deviceKey: json.encode(device.toJson()),
      });
      final Printly printly = Printly.forTesting();

      // The documented restore path: just load the persisted device.
      expect(await printly.loadLastConnectedDevice(), device);
      expect(printly.isAutoReconnectEnabled, isTrue);

      // Adapter comes back — the restored flag must act on its own.
      platform.adapter.add(BluetoothAdapterState.poweredOn);
      await pumpEventQueue();
      expect(platform.connectCalls, 1);

      // Resolve the retry so no timer outlives the test.
      platform.events.add(
        const PrintlyConnectionEvent(
          device: device,
          state: ConnectionState.connected,
        ),
      );
      await pumpEventQueue();
    });

    test('a persisted false flag does not arm the listener', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _autoReconnectKey: false,
        _deviceKey: json.encode(device.toJson()),
      });
      final Printly printly = Printly.forTesting();

      await printly.loadLastConnectedDevice();
      expect(printly.isAutoReconnectEnabled, isFalse);

      platform.adapter.add(BluetoothAdapterState.poweredOn);
      await pumpEventQueue();
      expect(platform.connectCalls, 0);
    });
  });
}

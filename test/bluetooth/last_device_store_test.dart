import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';
import 'package:printly/src/bluetooth/last_device_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const PrintlyDevice sampleDevice = PrintlyDevice(
    address: 'AA:BB:CC:DD:EE:FF',
    type: ConnectionType.ble,
    name: 'Printer',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('round-trips a device through persistent storage', () async {
    final LastDeviceStore store = await LastDeviceStore.open();
    expect(store.readDevice(), isNull);

    await store.writeDevice(sampleDevice);
    final LastDeviceStore reopened = await LastDeviceStore.open();
    expect(reopened.readDevice(), sampleDevice);
  });

  test('writeDevice(null) clears the persisted value', () async {
    final LastDeviceStore store = await LastDeviceStore.open();
    await store.writeDevice(sampleDevice);
    await store.writeDevice(null);
    expect((await LastDeviceStore.open()).readDevice(), isNull);
  });

  test('readDevice returns null for malformed JSON', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'printly.last_connected_device': 'not json',
    });
    final LastDeviceStore store = await LastDeviceStore.open();
    expect(store.readDevice(), isNull);
  });

  test('auto-reconnect flag round-trips', () async {
    final LastDeviceStore store = await LastDeviceStore.open();
    expect(store.readAutoReconnect(), isFalse);

    await store.writeAutoReconnect(enabled: true);
    final LastDeviceStore reopened = await LastDeviceStore.open();
    expect(reopened.readAutoReconnect(), isTrue);
  });
}

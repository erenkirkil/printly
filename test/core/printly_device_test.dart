import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';

void main() {
  group('PrintlyDevice equality', () {
    test('ignores rssi, name, and isBonded', () {
      const PrintlyDevice a = PrintlyDevice(
        address: 'AA:BB:CC:DD:EE:FF',
        type: ConnectionType.ble,
        name: 'Printer-A',
        rssi: -50,
      );
      const PrintlyDevice b = PrintlyDevice(
        address: 'AA:BB:CC:DD:EE:FF',
        type: ConnectionType.ble,
        name: 'Printer-B',
        rssi: -70,
        isBonded: true,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('distinguishes same address across transports', () {
      const PrintlyDevice classic = PrintlyDevice(
        address: 'AA:BB:CC:DD:EE:FF',
        type: ConnectionType.classic,
      );
      const PrintlyDevice ble = PrintlyDevice(
        address: 'AA:BB:CC:DD:EE:FF',
        type: ConnectionType.ble,
      );
      expect(classic == ble, isFalse);
    });
  });

  group('PrintlyDevice.dedupKey', () {
    test('combines type and address', () {
      const PrintlyDevice device = PrintlyDevice(
        address: 'AA:BB:CC:DD:EE:FF',
        type: ConnectionType.ble,
      );
      expect(device.dedupKey, 'ble:AA:BB:CC:DD:EE:FF');
    });
  });

  group('PrintlyDevice.network', () {
    test('uses host:port as address', () {
      final PrintlyDevice device = PrintlyDevice.network(
        host: '192.168.1.50',
        port: 9100,
      );
      expect(device.address, '192.168.1.50:9100');
      expect(device.type, ConnectionType.network);
    });

    test('defaults to port 9100', () {
      final PrintlyDevice device = PrintlyDevice.network(host: '10.0.0.1');
      expect(device.address, '10.0.0.1:9100');
    });
  });

  group('PrintlyDevice.copyWith', () {
    test('refreshes rssi without changing identity', () {
      const PrintlyDevice original = PrintlyDevice(
        address: 'AA:BB:CC:DD:EE:FF',
        type: ConnectionType.ble,
        rssi: -50,
      );
      final PrintlyDevice updated = original.copyWith(rssi: -40);
      expect(updated.rssi, -40);
      expect(updated, original);
    });

    test('keeps existing fields when arguments are null', () {
      const PrintlyDevice original = PrintlyDevice(
        address: 'AA:BB:CC:DD:EE:FF',
        type: ConnectionType.classic,
        name: 'Cashier',
        rssi: -60,
        isBonded: true,
      );
      final PrintlyDevice same = original.copyWith();
      expect(same.name, 'Cashier');
      expect(same.rssi, -60);
      expect(same.isBonded, isTrue);
    });
  });

  group('PrintlyDevice JSON round-trip', () {
    test('preserves address, type, and name', () {
      const PrintlyDevice original = PrintlyDevice(
        address: 'AA:BB:CC:DD:EE:FF',
        type: ConnectionType.ble,
        name: 'Cashier',
        rssi: -55,
        isBonded: true,
      );
      final PrintlyDevice? restored = PrintlyDevice.fromJson(original.toJson());
      expect(restored, isNotNull);
      expect(restored!.address, original.address);
      expect(restored.type, original.type);
      expect(restored.name, original.name);
    });

    test('fromJson returns null for malformed payloads', () {
      expect(PrintlyDevice.fromJson(<String, Object?>{}), isNull);
      expect(
        PrintlyDevice.fromJson(<String, Object?>{'address': 42, 'type': 1}),
        isNull,
      );
      expect(
        PrintlyDevice.fromJson(<String, Object?>{
          'address': 'AA:BB',
          'type': 'ble',
        }),
        isNull,
      );
    });
  });
}

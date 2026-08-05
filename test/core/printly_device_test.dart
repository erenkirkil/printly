import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';

void main() {
  group('PrintlyDevice equality', () {
    test('ignores rssi, name, isBonded, and availableTransports', () {
      final PrintlyDevice a = PrintlyDevice(
        address: 'AA:BB:CC:DD:EE:FF',
        availableTransports: <ConnectionType>{ConnectionType.ble},
        name: 'Printer-A',
        rssi: -50,
      );
      final PrintlyDevice b = PrintlyDevice(
        address: 'AA:BB:CC:DD:EE:FF',
        availableTransports: <ConnectionType>{ConnectionType.classic},
        name: 'Printer-B',
        rssi: -70,
        isBonded: true,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('distinguishes different addresses', () {
      final PrintlyDevice a = PrintlyDevice(
        address: 'AA:BB:CC:DD:EE:FF',
        availableTransports: <ConnectionType>{ConnectionType.classic},
      );
      final PrintlyDevice b = PrintlyDevice(
        address: '11:22:33:44:55:66',
        availableTransports: <ConnectionType>{ConnectionType.classic},
      );
      expect(a == b, isFalse);
    });

    test('dedupKey is the bare address — Classic and BLE ads merge', () {
      final PrintlyDevice classic = PrintlyDevice(
        address: 'AA:BB',
        availableTransports: <ConnectionType>{ConnectionType.classic},
      );
      final PrintlyDevice ble = PrintlyDevice(
        address: 'AA:BB',
        availableTransports: <ConnectionType>{ConnectionType.ble},
      );
      expect(classic.dedupKey, 'AA:BB');
      expect(classic, equals(ble));
      expect(classic.hashCode, ble.hashCode);
    });
  });

  group('PrintlyDevice.network', () {
    test('uses host:port as address', () {
      final PrintlyDevice device = PrintlyDevice.network(
        host: '192.168.1.50',
        port: 9100,
      );
      expect(device.address, '192.168.1.50:9100');
      expect(device.availableTransports, <ConnectionType>{
        ConnectionType.network,
      });
    });

    test('defaults to port 9100', () {
      final PrintlyDevice device = PrintlyDevice.network(host: '10.0.0.1');
      expect(device.address, '10.0.0.1:9100');
    });
  });

  group('PrintlyDevice.copyWith', () {
    test('refreshes rssi without changing identity', () {
      final PrintlyDevice original = PrintlyDevice(
        address: 'AA:BB:CC:DD:EE:FF',
        availableTransports: <ConnectionType>{ConnectionType.ble},
        rssi: -50,
      );
      final PrintlyDevice updated = original.copyWith(rssi: -40);
      expect(updated.rssi, -40);
      expect(updated, original);
    });

    test('keeps existing fields when arguments are null', () {
      final PrintlyDevice original = PrintlyDevice(
        address: 'AA:BB:CC:DD:EE:FF',
        availableTransports: <ConnectionType>{ConnectionType.classic},
        name: 'Cashier',
        rssi: -60,
        isBonded: true,
      );
      final PrintlyDevice same = original.copyWith();
      expect(same.name, 'Cashier');
      expect(same.rssi, -60);
      expect(same.isBonded, isTrue);
      expect(same.availableTransports, original.availableTransports);
    });

    test('can replace availableTransports', () {
      final PrintlyDevice original = PrintlyDevice(
        address: 'AA:BB',
        availableTransports: <ConnectionType>{ConnectionType.classic},
      );
      final PrintlyDevice updated = original.copyWith(
        availableTransports: <ConnectionType>{ConnectionType.ble},
      );
      expect(updated.availableTransports, <ConnectionType>{ConnectionType.ble});
    });
  });

  group('PrintlyDevice.mergeWith', () {
    test('mergeWith unions transports and ORs the flags', () {
      final PrintlyDevice seed = PrintlyDevice(
        address: 'AA:BB',
        availableTransports: <ConnectionType>{ConnectionType.classic},
        isBonded: true,
        seenInScan: false,
      );
      final PrintlyDevice ad = PrintlyDevice(
        address: 'AA:BB',
        availableTransports: <ConnectionType>{ConnectionType.ble},
        name: 'PTP-II',
        rssi: -60,
      );
      final PrintlyDevice merged = seed.mergeWith(ad);
      expect(merged.availableTransports, <ConnectionType>{
        ConnectionType.classic,
        ConnectionType.ble,
      });
      expect(merged.isBonded, isTrue);
      expect(merged.seenInScan, isTrue);
      expect(merged.name, 'PTP-II');
      expect(merged.rssi, -60);
    });

    test('prefers the existing name/rssi when the newer ad omits them', () {
      final PrintlyDevice seed = PrintlyDevice(
        address: 'AA:BB',
        availableTransports: <ConnectionType>{ConnectionType.ble},
        name: 'PTP-II',
        rssi: -55,
      );
      final PrintlyDevice ad = PrintlyDevice(
        address: 'AA:BB',
        availableTransports: <ConnectionType>{ConnectionType.ble},
      );
      final PrintlyDevice merged = seed.mergeWith(ad);
      expect(merged.name, 'PTP-II');
      expect(merged.rssi, -55);
    });
  });

  group('PrintlyDevice JSON round-trip', () {
    test('fromJson reads the legacy single-type persisted format', () {
      final PrintlyDevice? migrated = PrintlyDevice.fromJson(<String, Object?>{
        'address': 'AA:BB',
        'type': ConnectionType.classic.wireCode,
        'name': 'PTP-II',
      });
      expect(migrated, isNotNull);
      expect(migrated!.availableTransports, <ConnectionType>{
        ConnectionType.classic,
      });
      expect(migrated.name, 'PTP-II');
    });

    test('toJson/fromJson round-trips the new transports format', () {
      final PrintlyDevice d = PrintlyDevice(
        address: 'AA:BB',
        availableTransports: <ConnectionType>{
          ConnectionType.classic,
          ConnectionType.ble,
        },
        name: 'PTP-II',
      );
      final PrintlyDevice? back = PrintlyDevice.fromJson(d.toJson());
      expect(back, isNotNull);
      expect(back!.availableTransports, d.availableTransports);
      expect(back.name, d.name);
      expect(back.address, d.address);
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
      expect(
        PrintlyDevice.fromJson(<String, Object?>{
          'address': 'AA:BB',
          'transports': 'not-a-list',
        }),
        isNull,
      );
    });
  });

  group('PrintlyDevice.fromWireMap', () {
    test('defaults seenInScan to true and wraps the single type', () {
      final PrintlyDevice? d = PrintlyDevice.fromWireMap(<Object?, Object?>{
        'address': 'AA:BB',
        'type': ConnectionType.ble.wireCode,
        'rssi': -55,
      });
      expect(d, isNotNull);
      expect(d!.seenInScan, isTrue);
      expect(d.availableTransports, <ConnectionType>{ConnectionType.ble});
      expect(d.rssi, -55);

      final PrintlyDevice? seeded =
          PrintlyDevice.fromWireMap(<Object?, Object?>{
            'address': 'AA:BB',
            'type': ConnectionType.classic.wireCode,
            'seenInScan': false,
          });
      expect(seeded, isNotNull);
      expect(seeded!.seenInScan, isFalse);
    });

    test('decodes name, isBonded and returns null for malformed maps', () {
      final PrintlyDevice? d = PrintlyDevice.fromWireMap(<Object?, Object?>{
        'address': 'AA:BB:CC:DD:EE:FF',
        'type': 1,
        'name': 'Printer',
        'isBonded': true,
      });
      expect(d, isNotNull);
      expect(d!.name, 'Printer');
      expect(d.isBonded, isTrue);

      expect(PrintlyDevice.fromWireMap(<Object?, Object?>{'type': 0}), isNull);
      expect(
        PrintlyDevice.fromWireMap(<Object?, Object?>{'address': 'AA:BB'}),
        isNull,
      );
    });
  });

  group('PrintlyDevice.hasName', () {
    test('rejects null and whitespace-only names', () {
      PrintlyDevice make(String? n) => PrintlyDevice(
        address: 'A',
        name: n,
        availableTransports: <ConnectionType>{ConnectionType.ble},
      );
      expect(make(null).hasName, isFalse);
      expect(make('  ').hasName, isFalse);
      expect(make('PTP-II').hasName, isTrue);
    });
  });

  group('PrintlyDevice construction', () {
    test('asserts availableTransports is non-empty', () {
      expect(
        () => PrintlyDevice(
          address: 'AA:BB',
          availableTransports: const <ConnectionType>{},
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}

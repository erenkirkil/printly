import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';

void main() {
  group('ConnectionType.wireCode', () {
    test('is stable for each transport', () {
      expect(ConnectionType.classic.wireCode, 0);
      expect(ConnectionType.ble.wireCode, 1);
      expect(ConnectionType.network.wireCode, 2);
    });
  });

  group('ConnectionType.fromWireCode', () {
    test('round-trips every known code', () {
      for (final ConnectionType type in ConnectionType.values) {
        expect(ConnectionType.fromWireCode(type.wireCode), type);
      }
    });

    test('falls back to classic for unknown codes', () {
      expect(ConnectionType.fromWireCode(-1), ConnectionType.classic);
      expect(ConnectionType.fromWireCode(99), ConnectionType.classic);
    });
  });
}

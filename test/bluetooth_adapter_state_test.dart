import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';

void main() {
  group('BluetoothAdapterState.fromCode', () {
    test('maps every documented code', () {
      expect(BluetoothAdapterState.fromCode(0), BluetoothAdapterState.unknown);
      expect(
        BluetoothAdapterState.fromCode(1),
        BluetoothAdapterState.resetting,
      );
      expect(
        BluetoothAdapterState.fromCode(2),
        BluetoothAdapterState.unsupported,
      );
      expect(
        BluetoothAdapterState.fromCode(3),
        BluetoothAdapterState.unauthorized,
      );
      expect(
        BluetoothAdapterState.fromCode(4),
        BluetoothAdapterState.poweredOff,
      );
      expect(
        BluetoothAdapterState.fromCode(5),
        BluetoothAdapterState.poweredOn,
      );
    });

    test('falls back to unknown for unrecognised codes', () {
      expect(BluetoothAdapterState.fromCode(-1), BluetoothAdapterState.unknown);
      expect(BluetoothAdapterState.fromCode(42), BluetoothAdapterState.unknown);
    });
  });
}

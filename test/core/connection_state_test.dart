import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';

void main() {
  group('ConnectionState.wireCode', () {
    test('is stable for each state', () {
      expect(ConnectionState.disconnected.wireCode, 0);
      expect(ConnectionState.connecting.wireCode, 1);
      expect(ConnectionState.connected.wireCode, 2);
      expect(ConnectionState.disconnecting.wireCode, 3);
      expect(ConnectionState.reconnecting.wireCode, 4);
      expect(ConnectionState.error.wireCode, 5);
    });
  });

  group('ConnectionState.fromWireCode', () {
    test('round-trips every known code', () {
      for (final ConnectionState state in ConnectionState.values) {
        expect(ConnectionState.fromWireCode(state.wireCode), state);
      }
    });

    test('falls back to disconnected for unknown codes', () {
      expect(ConnectionState.fromWireCode(-1), ConnectionState.disconnected);
      expect(ConnectionState.fromWireCode(42), ConnectionState.disconnected);
    });
  });

  group('ConnectionState helpers', () {
    test('isConnected is true only for connected', () {
      for (final ConnectionState state in ConnectionState.values) {
        expect(state.isConnected, state == ConnectionState.connected);
      }
    });

    test('isInProgress covers connecting and reconnecting', () {
      expect(ConnectionState.connecting.isInProgress, isTrue);
      expect(ConnectionState.reconnecting.isInProgress, isTrue);
      expect(ConnectionState.disconnected.isInProgress, isFalse);
      expect(ConnectionState.connected.isInProgress, isFalse);
      expect(ConnectionState.disconnecting.isInProgress, isFalse);
      expect(ConnectionState.error.isInProgress, isFalse);
    });
  });
}

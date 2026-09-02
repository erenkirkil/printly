import 'package:flutter_test/flutter_test.dart';
import 'package:printly/src/network/network_address.dart';

void main() {
  group('NetworkAddress.parse', () {
    test('IPv4 host:port', () {
      final NetworkAddress a = NetworkAddress.parse('192.168.0.5:9100');
      expect(a.host, '192.168.0.5');
      expect(a.port, 9100);
      expect(a.canonical, '192.168.0.5:9100');
    });

    test('bracketed IPv6 host:port keeps the host without brackets', () {
      final NetworkAddress a = NetworkAddress.parse('[fe80::1]:9100');
      expect(a.host, 'fe80::1');
      expect(a.port, 9100);
      expect(a.canonical, '[fe80::1]:9100');
    });

    test('hostname host:port', () {
      final NetworkAddress a = NetworkAddress.parse('printer.local:9100');
      expect(a.host, 'printer.local');
      expect(a.port, 9100);
    });

    test('missing port throws FormatException', () {
      expect(() => NetworkAddress.parse('192.168.0.5'), throwsFormatException);
    });

    test('non-numeric port throws FormatException', () {
      expect(
        () => NetworkAddress.parse('192.168.0.5:abc'),
        throwsFormatException,
      );
    });

    test('port out of range throws FormatException', () {
      expect(
        () => NetworkAddress.parse('192.168.0.5:70000'),
        throwsFormatException,
      );
    });

    test('empty host throws FormatException', () {
      expect(() => NetworkAddress.parse(':9100'), throwsFormatException);
    });
  });
}

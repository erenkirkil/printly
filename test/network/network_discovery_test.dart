import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:printly/src/core/connection_type.dart';
import 'package:printly/src/core/printly_device.dart';
import 'package:printly/src/core/printly_exception.dart';
import 'package:printly/src/network/network_discovery.dart';

void main() {
  group('NetworkPrinterDiscovery.expandSubnet', () {
    test('expands a 3-octet /24 prefix to .1 through .254 in order', () {
      final List<String> hosts = NetworkPrinterDiscovery.expandSubnet(
        '192.168.0',
      );
      expect(hosts.length, 254);
      expect(hosts.first, '192.168.0.1');
      expect(hosts.last, '192.168.0.254');
    });

    test(
      'expands a 4-octet IPv4 address to its /24 excluding that address',
      () {
        final List<String> hosts = NetworkPrinterDiscovery.expandSubnet(
          '192.168.0.42',
        );
        expect(hosts.length, 253);
        expect(hosts, isNot(contains('192.168.0.42')));
        expect(hosts.first, '192.168.0.1');
        expect(hosts.last, '192.168.0.254');
      },
    );

    test('rejects malformed subnets', () {
      for (final String bad in <String>[
        '',
        '192.168',
        '192.168.0.1.2',
        '192.168.256',
        '192.168.-1',
        'abc.def.ghi',
      ]) {
        expect(
          () => NetworkPrinterDiscovery.expandSubnet(bad),
          throwsFormatException,
          reason: 'subnet="$bad" should fail',
        );
      }
    });
  });

  group('NetworkPrinterDiscovery interface & RFC1918 filtering', () {
    test('recognises private RFC 1918 IPv4 addresses only', () {
      expect(NetworkPrinterDiscovery.isPrivateIpv4('10.0.0.1'), isTrue);
      expect(NetworkPrinterDiscovery.isPrivateIpv4('10.255.255.254'), isTrue);
      expect(NetworkPrinterDiscovery.isPrivateIpv4('172.16.0.1'), isTrue);
      expect(NetworkPrinterDiscovery.isPrivateIpv4('172.31.255.254'), isTrue);
      expect(NetworkPrinterDiscovery.isPrivateIpv4('192.168.0.1'), isTrue);
      expect(NetworkPrinterDiscovery.isPrivateIpv4('192.168.255.254'), isTrue);

      // Loopback, link-local, 172 outside /12, CGNAT, and public IPs are
      // excluded so we never scan non-LAN ranges.
      expect(NetworkPrinterDiscovery.isPrivateIpv4('127.0.0.1'), isFalse);
      expect(NetworkPrinterDiscovery.isPrivateIpv4('169.254.1.1'), isFalse);
      expect(NetworkPrinterDiscovery.isPrivateIpv4('172.15.0.1'), isFalse);
      expect(NetworkPrinterDiscovery.isPrivateIpv4('172.32.0.1'), isFalse);
      expect(NetworkPrinterDiscovery.isPrivateIpv4('100.64.0.1'), isFalse);
      expect(NetworkPrinterDiscovery.isPrivateIpv4('8.8.8.8'), isFalse);
    });

    test('filters out cellular, VPN/tunnel, and loopback interface names', () {
      expect(NetworkPrinterDiscovery.isCandidateInterfaceName('wlan0'), isTrue);
      expect(NetworkPrinterDiscovery.isCandidateInterfaceName('en0'), isTrue);
      expect(NetworkPrinterDiscovery.isCandidateInterfaceName('eth0'), isTrue);

      for (final String nonLan in <String>[
        'lo',
        'lo0',
        'pdp_ip0',
        'rmnet0',
        'rmnet_data0',
        'ccmni0',
        'clat4',
        'tun0',
        'utun0',
        'utun4',
        'ppp0',
        'ipsec0',
        'wg0',
        'tailscale0',
        'awdl0',
        'llw0',
      ]) {
        expect(
          NetworkPrinterDiscovery.isCandidateInterfaceName(nonLan),
          isFalse,
          reason: 'interface "$nonLan" must be skipped',
        );
      }
    });

    test(
      'discovers across candidate LAN interfaces and skips own IPs',
      () async {
        final List<String> probed = <String>[];
        final List<PrintlyDevice>
        found = await NetworkPrinterDiscovery.discover(
          listInterfaces: () async => <String, List<String>>{
            'pdp_ip0': <String>['10.0.0.2'],
            'utun0': <String>['10.8.0.2'],
            'en0': <String>['192.168.1.10'],
            // Duplicate /24 on a second LAN interface (e.g. Wi-Fi + Ethernet on
            // the same subnet) must not scan the subnet twice, and both own IPs
            // must be excluded.
            'en1': <String>['192.168.1.11'],
          },
          connector: (String host, int port, {Duration? timeout}) async {
            probed.add(host);
            if (host == '192.168.1.50') {
              return _DummySocket();
            }
            throw const SocketException('refused');
          },
        );

        expect(probed.length, 252);
        expect(probed, isNot(contains('192.168.1.10')));
        expect(probed, isNot(contains('192.168.1.11')));
        expect(probed.any((String h) => h.startsWith('10.')), isFalse);
        expect(found.map((PrintlyDevice d) => d.address), <String>[
          '192.168.1.50:9100',
        ]);
      },
    );
  });

  group('NetworkPrinterDiscovery.discover probing', () {
    test('discovers a real loopback ServerSocket and destroys the probe socket '
        'without writing any bytes', () async {
      final ServerSocket server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final Completer<List<int>> receivedByPrinter = Completer<List<int>>();
      server.listen((Socket client) {
        final List<int> acc = <int>[];
        client.listen(
          acc.addAll,
          onDone: () {
            if (!receivedByPrinter.isCompleted) {
              receivedByPrinter.complete(acc);
            }
          },
        );
      });
      addTearDown(server.close);

      final List<PrintlyDevice> devices =
          await NetworkPrinterDiscovery.discover(
            hosts: <String>['127.0.0.1'],
            port: server.port,
          );

      expect(devices.length, 1);
      final PrintlyDevice printer = devices.single;
      expect(printer.address, '127.0.0.1:${server.port}');
      expect(printer.name, 'TCP 127.0.0.1:${server.port}');
      expect(printer.availableTransports, <ConnectionType>{
        ConnectionType.network,
      });
      expect(printer.seenInScan, isTrue);

      // The probe must disconnect cleanly with 0 bytes sent so a raw port-9100
      // printer never prints garbage during discovery.
      final List<int> bytes = await receivedByPrinter.future.timeout(
        const Duration(seconds: 1),
      );
      expect(bytes, isEmpty);
    });

    test('preserves candidate order even when an earlier host responds slower '
        'than a later host', () async {
      final List<PrintlyDevice> devices =
          await NetworkPrinterDiscovery.discover(
            hosts: <String>['192.168.0.10', '192.168.0.20', '192.168.0.30'],
            connector: (String host, int port, {Duration? timeout}) async {
              if (host == '192.168.0.10') {
                await Future<void>.delayed(const Duration(milliseconds: 40));
                return _DummySocket();
              }
              if (host == '192.168.0.20') {
                throw const SocketException('Connection refused');
              }
              if (host == '192.168.0.30') {
                return _DummySocket();
              }
              throw const SocketException('unreachable');
            },
          );

      expect(devices.map((PrintlyDevice d) => d.address).toList(), <String>[
        '192.168.0.10:9100',
        '192.168.0.30:9100',
      ]);
    });

    test('destroys a late-arriving socket after probeTimeout and absorbs late '
        'errors without leaking into the Zone', () async {
      final Completer<Socket> lateSuccess = Completer<Socket>();
      final Completer<Socket> lateError = Completer<Socket>();
      final _DummySocket lateSocket = _DummySocket();

      final List<PrintlyDevice> devices =
          await NetworkPrinterDiscovery.discover(
            hosts: <String>['192.168.0.10', '192.168.0.11'],
            probeTimeout: const Duration(milliseconds: 20),
            connector: (String host, int port, {Duration? timeout}) {
              if (host == '192.168.0.10') return lateSuccess.future;
              return lateError.future;
            },
          );

      expect(devices, isEmpty);

      // Complete both futures AFTER discovery has already timed out and
      // returned. The late socket must be destroyed and the late error
      // absorbed.
      lateSuccess.complete(lateSocket);
      lateError.completeError(const SocketException('late failure'));
      await Future<void>.delayed(Duration.zero);

      expect(lateSocket.destroyed, isTrue);
    });

    test('includes activeAddresses without opening a second TCP connection '
        '(single-socket printer protection)', () async {
      final List<String> dialed = <String>[];
      final List<PrintlyDevice> devices =
          await NetworkPrinterDiscovery.discover(
            hosts: <String>['192.168.0.5', '192.168.0.6'],
            activeAddresses: const <String>{'192.168.0.5:9100'},
            connector: (String host, int port, {Duration? timeout}) async {
              dialed.add(host);
              if (host == '192.168.0.6') return _DummySocket();
              throw const SocketException('refused');
            },
          );

      // 192.168.0.5 was already open in TcpPrinterTransport, so discovery must
      // not touch its socket (which on a 1-socket printer like Custom TK180
      // would either be refused or reset the active session), yet still report
      // it in the discovered list.
      expect(dialed, <String>['192.168.0.6']);
      expect(devices.map((PrintlyDevice d) => d.address).toList(), <String>[
        '192.168.0.5:9100',
        '192.168.0.6:9100',
      ]);
    });

    // A missing Android INTERNET permission (or a sandbox without the
    // network-client entitlement) fails every dial with EACCES / EPERM.
    // Reporting that as an empty list is indistinguishable from "no printers
    // on this LAN", so the sweep must fail loudly instead.
    test('an EACCES dial fails the sweep with a permissionDenied '
        'PrintlyScanException', () async {
      await expectLater(
        NetworkPrinterDiscovery.discover(
          hosts: <String>['192.168.0.5'],
          connector: (String host, int port, {Duration? timeout}) async {
            throw const SocketException(
              'Failed to create socket',
              osError: OSError('Permission denied', 13),
            );
          },
        ),
        throwsA(
          isA<PrintlyScanException>()
              .having(
                (PrintlyScanException e) => e.code,
                'code',
                PrintlyErrorCode.permissionDenied,
              )
              .having(
                (PrintlyScanException e) => e.message,
                'message',
                contains('Permission denied'),
              ),
        ),
      );
    });

    test('an EPERM dial fails the sweep with a permissionDenied '
        'PrintlyScanException', () async {
      await expectLater(
        NetworkPrinterDiscovery.discover(
          hosts: <String>['192.168.0.5'],
          connector: (String host, int port, {Duration? timeout}) async {
            throw const SocketException(
              'Connection failed',
              osError: OSError('Operation not permitted', 1),
            );
          },
        ),
        throwsA(
          isA<PrintlyScanException>().having(
            (PrintlyScanException e) => e.code,
            'code',
            PrintlyErrorCode.permissionDenied,
          ),
        ),
      );
    });

    test(
      'stops dialing the remaining hosts after a permission error',
      () async {
        int dials = 0;
        await expectLater(
          NetworkPrinterDiscovery.discover(
            hosts: <String>[
              '192.168.0.5',
              '192.168.0.6',
              '192.168.0.7',
              '192.168.0.8',
            ],
            concurrency: 1,
            connector: (String host, int port, {Duration? timeout}) async {
              dials++;
              throw const SocketException(
                'Failed to create socket',
                osError: OSError('Permission denied', 13),
              );
            },
          ),
          throwsA(isA<PrintlyScanException>()),
        );
        expect(dials, 1);
      },
    );

    // iOS reports a denied Local Network permission as EHOSTUNREACH (Darwin
    // errno 65) on every dial, instantly — measured on an iPhone 16 against a
    // live TK180. With the permission granted an empty LAN address times out
    // instead, so a sweep in which *every* probe failed with 65 is the denial,
    // not an empty network.
    test('a sweep where every probe fails with EHOSTUNREACH fails with a '
        'permissionDenied PrintlyScanException', () async {
      await expectLater(
        NetworkPrinterDiscovery.discover(
          hosts: <String>['192.168.0.5', '192.168.0.6', '192.168.0.7'],
          connector: (String host, int port, {Duration? timeout}) async {
            throw const SocketException(
              'Connection failed',
              osError: OSError('No route to host', 65),
            );
          },
        ),
        throwsA(
          isA<PrintlyScanException>()
              .having(
                (PrintlyScanException e) => e.code,
                'code',
                PrintlyErrorCode.permissionDenied,
              )
              .having(
                (PrintlyScanException e) => e.message,
                'message',
                contains('errno = 65'),
              ),
        ),
      );
    });

    // Measured on the iPhone with access denied: 252 of 253 probes failed
    // with 65 and one still timed out. With access granted, back-to-back
    // sweeps gave 0 × 65 (2 open, 251 timeouts), so "nearly all" is a safe
    // line where "all" was not.
    test('a stray timeout among EHOSTUNREACH probes is still read as the '
        'denial', () async {
      final Completer<Socket> never = Completer<Socket>();
      final List<String> hosts = List<String>.generate(
        20,
        (int i) => '192.168.0.${i + 1}',
      );
      await expectLater(
        NetworkPrinterDiscovery.discover(
          hosts: hosts,
          probeTimeout: const Duration(milliseconds: 20),
          connector: (String host, int port, {Duration? timeout}) async {
            if (host == '192.168.0.1') return never.future;
            throw const SocketException(
              'Connection failed',
              osError: OSError('No route to host', 65),
            );
          },
        ),
        throwsA(
          isA<PrintlyScanException>().having(
            (PrintlyScanException e) => e.code,
            'code',
            PrintlyErrorCode.permissionDenied,
          ),
        ),
      );
    });

    // Fence just under the line: 8 of 10 unreachable with nothing open is
    // still "no printers", not a denial.
    test(
      '80 % EHOSTUNREACH with the rest timing out returns an empty list',
      () async {
        final Completer<Socket> never = Completer<Socket>();
        final List<PrintlyDevice> devices =
            await NetworkPrinterDiscovery.discover(
              hosts: List<String>.generate(10, (int i) => '192.168.0.${i + 1}'),
              probeTimeout: const Duration(milliseconds: 20),
              connector: (String host, int port, {Duration? timeout}) async {
                if (host == '192.168.0.1' || host == '192.168.0.2') {
                  return never.future;
                }
                throw const SocketException(
                  'Connection failed',
                  osError: OSError('No route to host', 65),
                );
              },
            );

        expect(devices, isEmpty);
      },
    );

    // Fence: a single unreachable host is ordinary LAN noise once anything
    // else on the sweep behaves like a granted permission (here, a timeout).
    test(
      'EHOSTUNREACH mixed with a timed-out probe still returns a list',
      () async {
        final Completer<Socket> never = Completer<Socket>();
        final List<PrintlyDevice> devices =
            await NetworkPrinterDiscovery.discover(
              hosts: <String>['192.168.0.5', '192.168.0.6'],
              probeTimeout: const Duration(milliseconds: 20),
              connector: (String host, int port, {Duration? timeout}) async {
                if (host == '192.168.0.6') return never.future;
                throw const SocketException(
                  'Connection failed',
                  osError: OSError('No route to host', 65),
                );
              },
            );

        expect(devices, isEmpty);
      },
    );

    test(
      'EHOSTUNREACH mixed with a reachable printer returns that printer',
      () async {
        final List<PrintlyDevice> devices =
            await NetworkPrinterDiscovery.discover(
              hosts: <String>['192.168.0.5', '192.168.0.6'],
              connector: (String host, int port, {Duration? timeout}) async {
                if (host == '192.168.0.6') return _DummySocket();
                throw const SocketException(
                  'Connection failed',
                  osError: OSError('No route to host', 65),
                );
              },
            );

        expect(devices.map((PrintlyDevice d) => d.address).toList(), <String>[
          '192.168.0.6:9100',
        ]);
      },
    );

    test('an already-connected printer is returned even when every probe '
        'fails with EHOSTUNREACH', () async {
      final List<PrintlyDevice> devices =
          await NetworkPrinterDiscovery.discover(
            hosts: <String>['192.168.0.5', '192.168.0.6'],
            activeAddresses: const <String>{'192.168.0.5:9100'},
            connector: (String host, int port, {Duration? timeout}) async {
              throw const SocketException(
                'Connection failed',
                osError: OSError('No route to host', 65),
              );
            },
          );

      expect(devices.map((PrintlyDevice d) => d.address).toList(), <String>[
        '192.168.0.5:9100',
      ]);
    });

    // Fence: the permission guard must not turn an ordinary closed port into
    // a failed sweep — a refused host is simply not a printer.
    test(
      'a refused dial with an OS error still counts as unreachable',
      () async {
        final List<PrintlyDevice> devices =
            await NetworkPrinterDiscovery.discover(
              hosts: <String>['192.168.0.5', '192.168.0.6'],
              connector: (String host, int port, {Duration? timeout}) async {
                if (host == '192.168.0.6') return _DummySocket();
                throw const SocketException(
                  'Connection refused',
                  osError: OSError('Connection refused', 61),
                );
              },
            );

        expect(devices.map((PrintlyDevice d) => d.address).toList(), <String>[
          '192.168.0.6:9100',
        ]);
      },
    );

    test('validates port, concurrency, probeTimeout, and mutually exclusive '
        'subnet/hosts', () {
      expect(() => NetworkPrinterDiscovery.discover(port: 0), throwsRangeError);
      expect(
        () => NetworkPrinterDiscovery.discover(port: 70000),
        throwsRangeError,
      );
      expect(
        () => NetworkPrinterDiscovery.discover(concurrency: 0),
        throwsRangeError,
      );
      expect(
        () => NetworkPrinterDiscovery.discover(probeTimeout: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => NetworkPrinterDiscovery.discover(
          subnet: '192.168.0',
          hosts: <String>['192.168.0.5'],
        ),
        throwsArgumentError,
      );
    });
  });
}

class _DummySocket implements Socket {
  bool destroyed = false;

  @override
  void destroy() {
    destroyed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

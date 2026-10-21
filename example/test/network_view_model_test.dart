import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';
import 'package:printly_example/viewmodel/action_log_view_model.dart';
import 'package:printly_example/viewmodel/network_view_model.dart';
import 'package:printly_example/viewmodel/settings_view_model.dart';

void main() {
  late ActionLogViewModel log;
  late SettingsViewModel settings;
  late NetworkViewModel vm;

  setUp(() {
    log = ActionLogViewModel();
    settings = SettingsViewModel();
    // NOTE: start() is deliberately NOT called — it subscribes to a live
    // platform stream. Everything asserted here is pure state.
    vm = NetworkViewModel(log: log, settings: settings);
  });

  tearDown(() {
    vm.dispose();
    settings.dispose();
    log.dispose();
  });

  test('defaults to port 9100 and an empty host', () {
    expect(vm.port, 9100);
    expect(vm.host, isEmpty);
    expect(vm.device, isNull);
    expect(vm.canConnect, isFalse);
  });

  test('setting a host builds a network device with host:port address', () {
    vm.host = '192.168.0.5';
    expect(vm.device, isNotNull);
    expect(vm.device!.address, '192.168.0.5:9100');
    expect(vm.device!.availableTransports, <ConnectionType>{
      ConnectionType.network,
    });
    expect(vm.canConnect, isTrue);
  });

  test('a custom port is reflected in the address', () {
    vm.host = '10.0.0.9';
    vm.port = 9101;
    expect(vm.device!.address, '10.0.0.9:9101');
  });

  test('host is trimmed', () {
    vm.host = '  192.168.0.5  ';
    expect(vm.device!.address, '192.168.0.5:9100');
  });

  test('useRecent restores host and port from a host:port string', () {
    vm.useRecent('192.168.1.20:9102');
    expect(vm.host, '192.168.1.20');
    expect(vm.port, 9102);
  });

  test('setting the same host twice does not notify twice', () {
    int notifications = 0;
    vm.addListener(() => notifications++);
    vm.host = '192.168.0.5';
    vm.host = '192.168.0.5';
    expect(notifications, 1);
  });

  test('canPrint is false while disconnected', () {
    vm.host = '192.168.0.5';
    expect(vm.state, ConnectionState.disconnected);
    expect(vm.canPrint, isFalse);
  });

  test('ticketMode defaults to off so roll-paper printers are unaffected', () {
    expect(vm.ticketMode, isFalse);
  });

  test(
    'setting ticketMode notifies once, and not again for the same value',
    () {
      int notifications = 0;
      vm.addListener(() => notifications++);
      vm.ticketMode = true;
      vm.ticketMode = true;
      expect(vm.ticketMode, isTrue);
      expect(notifications, 1);
    },
  );

  group('persistence & LAN discovery / failed-connect sweep', () {
    test('restoreLastDevice populates host, port, and recents when last device '
        'was a network printer', () async {
      final NetworkViewModel customVm = NetworkViewModel(
        log: log,
        settings: settings,
        loadLastDevice: () async =>
            PrintlyDevice.network(host: '192.168.0.214', port: 9100),
      );
      addTearDown(customVm.dispose);

      await customVm.restoreLastDevice();

      expect(customVm.host, '192.168.0.214');
      expect(customVm.port, 9100);
      expect(customVm.recents, <String>['192.168.0.214:9100']);
    });

    test(
      'restoreLastDevice ignores a Bluetooth last-connected device',
      () async {
        final NetworkViewModel customVm = NetworkViewModel(
          log: log,
          settings: settings,
          loadLastDevice: () async => PrintlyDevice(
            name: 'PTP-II',
            address: 'AA:BB:CC:DD:EE:FF',
            availableTransports: const <ConnectionType>{ConnectionType.classic},
          ),
        );
        addTearDown(customVm.dispose);

        await customVm.restoreLastDevice();

        expect(customVm.host, isEmpty);
        expect(customVm.recents, isEmpty);
      },
    );

    test(
      'restoreLastDevice never clobbers a host the user already typed',
      () async {
        final Completer<PrintlyDevice?> completer = Completer<PrintlyDevice?>();
        final NetworkViewModel customVm = NetworkViewModel(
          log: log,
          settings: settings,
          loadLastDevice: () => completer.future,
        );
        addTearDown(customVm.dispose);

        final Future<void> restore = customVm.restoreLastDevice();
        // User starts typing before storage resolves.
        customVm.host = '10.0.0.50';
        completer.complete(
          PrintlyDevice.network(host: '192.168.0.214', port: 9100),
        );
        await restore;

        expect(customVm.host, '10.0.0.50');
      },
    );

    test('scanNetwork populates discovered printers and auto-fills host when '
        'a single printer is found', () async {
      final NetworkViewModel customVm = NetworkViewModel(
        log: log,
        settings: settings,
        discoverPrinters: ({required int port}) async => <PrintlyDevice>[
          PrintlyDevice.network(host: '192.168.0.105', port: port),
        ],
      );
      addTearDown(customVm.dispose);

      await customVm.scanNetwork();

      expect(customVm.discovered.length, 1);
      expect(customVm.discovered.single.address, '192.168.0.105:9100');
      expect(customVm.host, '192.168.0.105');
      expect(customVm.port, 9100);
    });

    // A lone responder on 9100 is not proof it is *this* counter's printer:
    // the real one may be powered off or held by another terminal (single
    // socket), and the responder another counter's printer or a PCL office
    // printer. The user must pick it explicitly from `discovered`.
    test('a failed connect surfaces a single LAN printer in discovered '
        'without connecting to it', () async {
      final List<String> connectAttempts = <String>[];
      final NetworkViewModel customVm = NetworkViewModel(
        log: log,
        settings: settings,
        connectDevice: (PrintlyDevice d) async {
          connectAttempts.add(d.address);
          if (d.address == '192.168.0.214:9100') {
            throw const PrintlyConnectionException(
              PrintlyErrorCode.connectTimeout,
              'stale IP timed out',
            );
          }
        },
        discoverPrinters: ({required int port}) async => <PrintlyDevice>[
          PrintlyDevice.network(host: '192.168.0.105', port: port),
        ],
      );
      addTearDown(customVm.dispose);

      customVm.host = '192.168.0.214';
      await customVm.connect();

      expect(connectAttempts, <String>['192.168.0.214:9100']);
      expect(customVm.host, '192.168.0.214');
      expect(
        customVm.discovered.map((PrintlyDevice d) => d.address).toList(),
        <String>['192.168.0.105:9100'],
      );
    });

    test('a failed connect keeps the saved address in recents', () async {
      final NetworkViewModel customVm = NetworkViewModel(
        log: log,
        settings: settings,
        loadLastDevice: () async =>
            PrintlyDevice.network(host: '192.168.0.214', port: 9100),
        connectDevice: (PrintlyDevice d) async {
          if (d.address == '192.168.0.214:9100') {
            throw const PrintlyConnectionException(
              PrintlyErrorCode.connectFailed,
              'printer powered off',
            );
          }
        },
        discoverPrinters: ({required int port}) async => <PrintlyDevice>[
          PrintlyDevice.network(host: '192.168.0.105', port: port),
        ],
      );
      addTearDown(customVm.dispose);

      await customVm.restoreLastDevice();
      await customVm.connect();

      expect(customVm.recents, <String>['192.168.0.214:9100']);
    });

    test('a failed connect logs the connect error even when the LAN sweep '
        'finds printers', () async {
      final NetworkViewModel customVm = NetworkViewModel(
        log: log,
        settings: settings,
        connectDevice: (PrintlyDevice d) async {
          if (d.address == '192.168.0.214:9100') {
            throw const PrintlyConnectionException(
              PrintlyErrorCode.connectTimeout,
              'stale IP timed out',
            );
          }
        },
        discoverPrinters: ({required int port}) async => <PrintlyDevice>[
          PrintlyDevice.network(host: '192.168.0.105', port: port),
        ],
      );
      addTearDown(customVm.dispose);

      customVm.host = '192.168.0.214';
      await customVm.connect();

      expect(
        log.entries.where(
          (e) => e.isError && e.message.contains('stale IP timed out'),
        ),
        hasLength(1),
      );
    });

    test('a failed connect surfaces multiple LAN printers in discovered '
        'without connecting to any', () async {
      final List<String> connectAttempts = <String>[];
      final NetworkViewModel customVm = NetworkViewModel(
        log: log,
        settings: settings,
        connectDevice: (PrintlyDevice d) async {
          connectAttempts.add(d.address);
          throw const PrintlyConnectionException(
            PrintlyErrorCode.connectTimeout,
            'stale IP timed out',
          );
        },
        discoverPrinters: ({required int port}) async => <PrintlyDevice>[
          PrintlyDevice.network(host: '192.168.0.105', port: port),
          PrintlyDevice.network(host: '192.168.0.106', port: port),
        ],
      );
      addTearDown(customVm.dispose);

      customVm.host = '192.168.0.214';
      await customVm.connect();

      // Only the initial attempt was made; both candidates are surfaced in
      // `discovered` so the user can choose rather than printing to the wrong
      // counter.
      expect(connectAttempts, <String>['192.168.0.214:9100']);
      expect(
        customVm.discovered.map((PrintlyDevice d) => d.address).toList(),
        <String>['192.168.0.105:9100', '192.168.0.106:9100'],
      );
    });
  });
}

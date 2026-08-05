import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:printly/printly.dart';
import 'package:printly/src/bluetooth/scan_controller.dart';
import 'package:printly/src/platform/printly_platform_interface.dart';

class _FakePlatform extends PrintlyPlatform with MockPlatformInterfaceMixin {
  final StreamController<PrintlyDevice> _resultsController =
      StreamController<PrintlyDevice>.broadcast();

  int startScanCalls = 0;
  int stopScanCalls = 0;
  Set<ConnectionType>? lastTypes;
  final List<Set<ConnectionType>> typesCalls = <Set<ConnectionType>>[];
  Completer<void>? startCompleter;
  Object? startError;
  Object? startErrorOnCall;

  @override
  Stream<PrintlyDevice> get scanResults => _resultsController.stream;

  @override
  Future<void> startScan({required Set<ConnectionType> types}) async {
    startScanCalls++;
    lastTypes = types;
    typesCalls.add(types);
    if (startCompleter != null) await startCompleter!.future;
    if (startErrorOnCall != null && startScanCalls == 2) {
      throw startErrorOnCall!;
    }
    if (startError != null) throw startError!;
  }

  @override
  Future<void> stopScan() async {
    stopScanCalls++;
  }

  void emit(PrintlyDevice device) => _resultsController.add(device);

  Future<void> close() async {
    await _resultsController.close();
  }

  @override
  Future<void> connect({
    required PrintlyDevice device,
    required ConnectionType transport,
    Duration? timeout,
  }) async {}

  @override
  Future<void> disconnect({
    required PrintlyDevice device,
    required ConnectionType transport,
  }) async {}

  @override
  Stream<PrintlyConnectionEvent> get connectionEvents =>
      const Stream<PrintlyConnectionEvent>.empty();
}

void main() {
  late _FakePlatform platform;
  late ScanController controller;

  setUp(() {
    platform = _FakePlatform();
    // Zero interval → emit immediately, so discovery assertions are synchronous.
    controller = ScanController(
      platform: platform,
      emitInterval: Duration.zero,
    );
  });

  tearDown(() async {
    await controller.dispose();
    await platform.close();
  });

  group('re-entrancy', () {
    test('concurrent startScan calls share one native scan', () async {
      platform.startCompleter = Completer<void>();
      final Future<void> first = controller.startScan();
      final Future<void> second = controller.startScan();
      expect(identical(first, second), isTrue);

      platform.startCompleter!.complete();
      await Future.wait(<Future<void>>[first, second]);

      expect(platform.startScanCalls, 1);
      expect(controller.isScanning, isTrue);
    });

    test('startScan is a no-op while already scanning', () async {
      await controller.startScan();
      expect(controller.isScanning, isTrue);
      await controller.startScan();
      expect(platform.startScanCalls, 1);
    });

    test('stopScan is a no-op when not scanning', () async {
      await controller.stopScan();
      expect(platform.stopScanCalls, 0);
    });

    test('concurrent stopScan calls share one native stop', () async {
      await controller.startScan();
      final Future<void> a = controller.stopScan();
      final Future<void> b = controller.stopScan();
      expect(identical(a, b), isTrue);
      await Future.wait(<Future<void>>[a, b]);
      expect(platform.stopScanCalls, 1);
    });

    test('startScan issued while a stopScan is in flight restarts', () async {
      await controller.startScan();
      // The natural "rescan" gesture: stop and start without awaiting.
      final Future<void> stop = controller.stopScan();
      final Future<void> restart = controller.startScan();
      await Future.wait(<Future<void>>[stop, restart]);

      expect(platform.stopScanCalls, 1);
      expect(platform.startScanCalls, 2);
      expect(controller.isScanning, isTrue);
    });

    test('restart queued behind a stop is shared by duplicate taps', () async {
      await controller.startScan();
      unawaited(controller.stopScan());
      final Future<void> first = controller.startScan();
      final Future<void> second = controller.startScan();
      expect(identical(first, second), isTrue);
      await first;
      expect(platform.startScanCalls, 2);
    });
  });

  group('mid-scan errors', () {
    test(
      'a native stream error surfaces on scanErrors and stops the scan',
      () async {
        await controller.startScan();
        expect(controller.isScanning, isTrue);

        final Future<PrintlyException> firstError = controller.scanErrors.first;
        platform._resultsController.addError(
          PlatformException(
            code: 'start_scan_failed',
            message: 'bluetooth_not_powered_on',
          ),
        );
        final PrintlyException error = await firstError;

        expect(error, isA<PrintlyScanException>());
        expect(error.code, PrintlyErrorCode.bluetoothNotPoweredOn);
        expect(controller.isScanning, isFalse);
      },
    );

    test('the controller keeps working after a stream error', () async {
      await controller.startScan();
      platform._resultsController.addError(
        PlatformException(code: 'start_scan_failed'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.isScanning, isFalse);

      await controller.startScan();
      expect(controller.isScanning, isTrue);
      expect(platform.startScanCalls, 2);
    });
  });

  group('dedup + merge', () {
    test('merges repeat advertisements by transport+address', () async {
      await controller.startScan();
      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          availableTransports: <ConnectionType>{ConnectionType.ble},
          rssi: -60,
        ),
      );
      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          availableTransports: <ConnectionType>{ConnectionType.ble},
          name: 'Printer',
          rssi: -50,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.currentDevices, hasLength(1));
      expect(controller.currentDevices.first.name, 'Printer');
      expect(controller.currentDevices.first.rssi, -50);
    });

    test('same address on different transports merges into one entry '
        '(dual-mode radios no longer appear twice)', () async {
      await controller.startScan();
      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          availableTransports: <ConnectionType>{ConnectionType.classic},
        ),
      );
      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          availableTransports: <ConnectionType>{ConnectionType.ble},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.currentDevices, hasLength(1));
      expect(
        controller.currentDevices.single.availableTransports,
        <ConnectionType>{ConnectionType.classic, ConnectionType.ble},
      );
    });

    test('keeps existing name when a later advertisement omits it', () async {
      await controller.startScan();
      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          availableTransports: <ConnectionType>{ConnectionType.ble},
          name: 'Printer',
          rssi: -55,
        ),
      );
      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          availableTransports: <ConnectionType>{ConnectionType.ble},
          rssi: -40,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final PrintlyDevice merged = controller.currentDevices.single;
      expect(merged.name, 'Printer');
      expect(merged.rssi, -40);
    });

    test('startScan clears previous device list', () async {
      await controller.startScan();
      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          availableTransports: <ConnectionType>{ConnectionType.ble},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.currentDevices, hasLength(1));

      await controller.stopScan();
      await controller.startScan();
      expect(controller.currentDevices, isEmpty);
    });
  });

  group('lifecycle + errors', () {
    test('timeout auto-stops the scan', () async {
      await controller.startScan(timeout: const Duration(milliseconds: 50));
      expect(controller.isScanning, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(platform.stopScanCalls, 1);
      expect(controller.isScanning, isFalse);
    });

    test('startScan failure resets isScanning to false', () async {
      platform.startError = Exception('bluetooth off');
      await expectLater(controller.startScan(), throwsA(isA<Exception>()));
      expect(controller.isScanning, isFalse);
    });

    test('dispose closes subjects and ignores later events', () async {
      await controller.startScan();
      await controller.dispose();
      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          availableTransports: <ConnectionType>{ConnectionType.ble},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      // Disposed — no throws, further public calls raise StateError.
      expect(() => controller.clearDevices(), throwsStateError);
    });

    test('passes types through to the platform', () async {
      await controller.startScan(
        types: const <ConnectionType>{ConnectionType.ble},
      );
      expect(platform.lastTypes, <ConnectionType>{ConnectionType.ble});
    });
  });

  group('field-informed defaults + seenInScan + includeBonded', () {
    test('same address over Classic and BLE yields ONE record with both '
        'transports', () async {
      await controller.startScan(timeout: const Duration(days: 1));
      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          availableTransports: <ConnectionType>{ConnectionType.classic},
          name: 'PTP-II',
        ),
      );
      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          availableTransports: <ConnectionType>{ConnectionType.ble},
          rssi: -58,
        ),
      );
      await pumpEventQueue();
      expect(controller.currentDevices, hasLength(1));
      expect(
        controller.currentDevices.single.availableTransports,
        <ConnectionType>{ConnectionType.classic, ConnectionType.ble},
      );
      expect(controller.currentDevices.single.name, 'PTP-II');
    });

    test('a bonded seed later seen in inquiry updates the SAME record to '
        'seenInScan', () async {
      await controller.startScan(timeout: const Duration(days: 1));
      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          isBonded: true,
          seenInScan: false,
          availableTransports: <ConnectionType>{ConnectionType.classic},
        ),
      );
      await pumpEventQueue();
      expect(controller.currentDevices.single.seenInScan, isFalse);
      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          availableTransports: <ConnectionType>{ConnectionType.classic},
        ),
      );
      await pumpEventQueue();
      expect(controller.currentDevices, hasLength(1));
      expect(controller.currentDevices.single.seenInScan, isTrue);
    });

    test('includeBonded: false drops bonded-only seeds but keeps devices '
        'actually seen', () async {
      await controller.startScan(
        timeout: const Duration(days: 1),
        includeBonded: false,
      );
      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          isBonded: true,
          seenInScan: false,
          availableTransports: <ConnectionType>{ConnectionType.classic},
        ),
      );
      platform.emit(
        PrintlyDevice(
          address: 'CC:DD',
          isBonded: true,
          availableTransports: <ConnectionType>{ConnectionType.classic},
        ),
      );
      await pumpEventQueue();
      expect(controller.currentDevices, hasLength(1));
      expect(controller.currentDevices.single.address, 'CC:DD');
    });

    test('defaultScanTypesForPlatform: iOS never asks for classic', () {
      expect(
        ScanController.defaultScanTypesForPlatform(isIOS: true),
        <ConnectionType>{ConnectionType.ble},
      );
      expect(
        ScanController.defaultScanTypesForPlatform(isIOS: false),
        <ConnectionType>{ConnectionType.classic, ConnectionType.ble},
      );
    });

    test('kDefaultScanTimeout is 10 seconds', () {
      expect(kDefaultScanTimeout, const Duration(seconds: 10));
    });
  });

  group('emission coalescing', () {
    test('collapses a burst of advertisements into one emission', () async {
      final ScanController coalesced = ScanController(
        platform: platform,
        emitInterval: const Duration(milliseconds: 50),
      );
      final List<int> lengths = <int>[];
      final StreamSubscription<List<PrintlyDevice>> sub = coalesced
          .devicesStream
          .listen((List<PrintlyDevice> list) => lengths.add(list.length));
      await Future<void>.delayed(Duration.zero); // seeded empty emission

      for (int i = 0; i < 10; i++) {
        platform.emit(
          PrintlyDevice(
            address: 'D$i',
            availableTransports: <ConnectionType>{ConnectionType.ble},
          ),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 90));

      // All 10 devices land, but the burst collapses to a single update.
      expect(lengths.last, 10);
      expect(lengths.length, lessThan(5));

      await sub.cancel();
      await coalesced.dispose();
    });
  });

  group('classicFirst scan strategy', () {
    test('(a) no named device in round 1: falls back to a single BLE round, '
        'preserving the device list and staying "scanning" across the '
        'transition', () async {
      final List<bool> scanningFlags = <bool>[];
      final StreamSubscription<bool> sub = controller.isScanningStream.listen(
        scanningFlags.add,
      );

      await controller.startScan(
        timeout: const Duration(milliseconds: 30),
        strategy: ScanStrategy.classicFirst,
      );
      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          availableTransports: <ConnectionType>{ConnectionType.classic},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.currentDevices, hasLength(1));

      // Past round 1's window (30ms), inside round 2's window (next 30ms).
      await Future<void>.delayed(const Duration(milliseconds: 45));

      expect(platform.typesCalls, <Set<ConnectionType>>[
        <ConnectionType>{ConnectionType.classic},
        <ConnectionType>{ConnectionType.ble},
      ]);
      // Round 2 does not clear what round 1 already found.
      expect(controller.currentDevices, hasLength(1));
      expect(controller.currentDevices.single.address, 'AA:BB');
      // No false emitted between the seeded value, the scan starting, and
      // now — the classic->ble transition must not flicker isScanning.
      expect(scanningFlags, <bool>[false, true]);
      expect(controller.isScanning, isTrue);

      await sub.cancel();
    });

    test('(b) a named+seenInScan device answers round 1: single platform call, '
        'no BLE fallback round', () async {
      await controller.startScan(
        timeout: const Duration(milliseconds: 20),
        strategy: ScanStrategy.classicFirst,
      );
      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          availableTransports: <ConnectionType>{ConnectionType.classic},
          name: 'PTP-II',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(platform.typesCalls, <Set<ConnectionType>>[
        <ConnectionType>{ConnectionType.classic},
      ]);
      expect(platform.stopScanCalls, 1);
      expect(controller.isScanning, isFalse);
    });

    test('(c) round 2 also finds nothing: no third round is ever started and '
        'isScanning ends false', () async {
      await controller.startScan(
        timeout: const Duration(milliseconds: 20),
        strategy: ScanStrategy.classicFirst,
      );
      await Future<void>.delayed(const Duration(milliseconds: 90));

      expect(platform.typesCalls, <Set<ConnectionType>>[
        <ConnectionType>{ConnectionType.classic},
        <ConnectionType>{ConnectionType.ble},
      ]);
      expect(platform.stopScanCalls, 2);
      expect(controller.isScanning, isFalse);
    });

    test('(d) parallel strategy issues a single call with the given types '
        'verbatim', () async {
      await controller.startScan(
        types: const <ConnectionType>{ConnectionType.ble},
        strategy: ScanStrategy.parallel,
      );
      expect(platform.typesCalls, <Set<ConnectionType>>[
        <ConnectionType>{ConnectionType.ble},
      ]);
      expect(platform.startScanCalls, 1);
    });

    test('(e) manual stopScan during round 1 cancels the whole strategy — no '
        'fallback round', () async {
      await controller.startScan(
        timeout: const Duration(days: 1),
        strategy: ScanStrategy.classicFirst,
      );
      expect(platform.typesCalls, <Set<ConnectionType>>[
        <ConnectionType>{ConnectionType.classic},
      ]);

      await controller.stopScan();
      // Give any (incorrect) fallback logic a chance to fire.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(platform.typesCalls, <Set<ConnectionType>>[
        <ConnectionType>{ConnectionType.classic},
      ]);
      expect(controller.isScanning, isFalse);
    });

    test('(f) a bonded-seed-only named device (seenInScan false) does not '
        'count as "found" — fallback still runs', () async {
      await controller.startScan(
        timeout: const Duration(milliseconds: 30),
        strategy: ScanStrategy.classicFirst,
      );
      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          isBonded: true,
          seenInScan: false,
          name: 'PTP-II',
          availableTransports: <ConnectionType>{ConnectionType.classic},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      await Future<void>.delayed(const Duration(milliseconds: 45));

      expect(platform.typesCalls, <Set<ConnectionType>>[
        <ConnectionType>{ConnectionType.classic},
        <ConnectionType>{ConnectionType.ble},
      ]);
      expect(controller.isScanning, isTrue);
    });

    test("round 2's native startScan failing surfaces through scanErrors and "
        'ends the scan', () async {
      platform.startErrorOnCall = PlatformException(
        code: 'start_scan_failed',
        message: 'bluetooth_not_powered_on',
      );
      final Future<PrintlyException> firstError = controller.scanErrors.first;

      await controller.startScan(
        timeout: const Duration(milliseconds: 20),
        strategy: ScanStrategy.classicFirst,
      );
      final PrintlyException error = await firstError;

      expect(error, isA<PrintlyScanException>());
      expect(error.code, PrintlyErrorCode.bluetoothNotPoweredOn);
      expect(controller.isScanning, isFalse);
      expect(platform.typesCalls, <Set<ConnectionType>>[
        <ConnectionType>{ConnectionType.classic},
        <ConnectionType>{ConnectionType.ble},
      ]);
    });
  });
}

import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:printly/printly.dart';
import 'package:printly/src/bluetooth/scan_controller.dart';

class _FakePlatform extends PrintlyPlatform with MockPlatformInterfaceMixin {
  final StreamController<PrintlyDevice> _resultsController =
      StreamController<PrintlyDevice>.broadcast();

  int startScanCalls = 0;
  int stopScanCalls = 0;
  Set<ConnectionType>? lastTypes;
  final List<Set<ConnectionType>> typesCalls = <Set<ConnectionType>>[];
  Completer<void>? startCompleter;
  Completer<void>? stopCompleter;
  Object? startError;
  Object? startErrorOnCall;

  @override
  Stream<PrintlyDevice> get scanResults => _resultsController.stream;

  final List<bool> includeUnnamedCalls = <bool>[];

  @override
  Future<void> startScan({
    required Set<ConnectionType> types,
    bool includeUnnamed = false,
  }) async {
    startScanCalls++;
    lastTypes = types;
    typesCalls.add(types);
    includeUnnamedCalls.add(includeUnnamed);
    if (startCompleter != null) await startCompleter!.future;
    if (startErrorOnCall != null && startScanCalls == 2) {
      throw startErrorOnCall!;
    }
    if (startError != null) throw startError!;
  }

  @override
  Future<void> stopScan() async {
    stopScanCalls++;
    if (stopCompleter != null) await stopCompleter!.future;
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

/// Extends [_FakePlatform] to let a specific numbered `startScan` call be
/// held open on a [Completer] — used to deterministically land a manual
/// [ScanController.stopScan] call in the middle of the round-1→round-2
/// transition's `await _platform.startScan(...)`, reproducing the orphaned
/// native scan regression. [_FakePlatform.startCompleter] gates every call
/// uniformly and cannot isolate a single round, hence this local subclass
/// instead of touching the shared fake.
class _GatedStartPlatform extends _FakePlatform {
  /// 1-indexed call number to gate (e.g. 2 = round 2's startScan).
  int gateAtCallNumber = 0;
  Completer<void>? gateOnCall;

  @override
  Future<void> startScan({
    required Set<ConnectionType> types,
    bool includeUnnamed = false,
  }) async {
    startScanCalls++;
    lastTypes = types;
    typesCalls.add(types);
    includeUnnamedCalls.add(includeUnnamed);
    if (startScanCalls == gateAtCallNumber && gateOnCall != null) {
      await gateOnCall!.future;
    }
    if (startErrorOnCall != null && startScanCalls == 2) {
      throw startErrorOnCall!;
    }
    if (startError != null) throw startError!;
  }
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
          name: 'PTP-II',
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
      // A scan must actually be running: discoveries landing with no scan
      // in flight are dropped (the post-stop late-result guard).
      await coalesced.startScan();
      final List<int> lengths = <int>[];
      final StreamSubscription<List<PrintlyDevice>> sub = coalesced
          .devicesStream
          .listen((List<PrintlyDevice> list) => lengths.add(list.length));
      await Future<void>.delayed(Duration.zero); // seeded empty emission

      for (int i = 0; i < 10; i++) {
        platform.emit(
          PrintlyDevice(
            address: 'D$i',
            name: 'Printer $i',
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

    test(
      'classicFirst ignores an explicit types: on round 1, non-iOS host',
      () async {
        await controller.startScan(
          types: const <ConnectionType>{ConnectionType.ble},
          strategy: ScanStrategy.classicFirst,
        );
        expect(platform.typesCalls, <Set<ConnectionType>>[
          <ConnectionType>{ConnectionType.classic},
        ]);
      },
    );
  });

  group('roundOneTypes', () {
    test('iOS -> {ble}, non-iOS -> {classic}', () {
      expect(ScanController.roundOneTypes(isIOS: true), <ConnectionType>{
        ConnectionType.ble,
      });
      expect(ScanController.roundOneTypes(isIOS: false), <ConnectionType>{
        ConnectionType.classic,
      });
    });
  });

  group('orphaned scan on stopScan race', () {
    test('a manual stopScan racing the round-1->round-2 transition stops the '
        'just-started BLE scan instead of orphaning it', () async {
      final _GatedStartPlatform gatedPlatform = _GatedStartPlatform();
      final ScanController gatedController = ScanController(
        platform: gatedPlatform,
        emitInterval: Duration.zero,
      );
      addTearDown(() async {
        await gatedController.dispose();
        await gatedPlatform.close();
      });

      // Gate round 2's startScan({ble}) — the 2nd call — open on a
      // Completer so a concurrent stopScan() can be driven to completion
      // while it is in flight.
      gatedPlatform.gateAtCallNumber = 2;
      gatedPlatform.gateOnCall = Completer<void>();

      unawaited(
        gatedController.startScan(
          timeout: const Duration(milliseconds: 20),
          strategy: ScanStrategy.classicFirst,
        ),
      );

      // Let round 1 elapse with nothing named; the transition stops
      // round 1's classic scan and dispatches round 2's startScan({ble}),
      // which is now parked on the gate.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(gatedPlatform.typesCalls, <Set<ConnectionType>>[
        <ConnectionType>{ConnectionType.classic},
        <ConnectionType>{ConnectionType.ble},
      ]);
      expect(gatedPlatform.stopScanCalls, 1); // round 1's stop only so far

      // Concurrent manual stop, racing the still-gated round-2 startScan.
      await gatedController.stopScan();
      expect(gatedController.isScanning, isFalse);
      expect(gatedPlatform.stopScanCalls, 2);

      // Release the gate: round 2's startScan resolves inside
      // _runFallbackRound, which must now observe isScanning == false and
      // issue a FINAL stopScan to avoid leaving an orphaned native BLE
      // scan running forever.
      gatedPlatform.gateOnCall!.complete();
      await pumpEventQueue();

      expect(gatedPlatform.stopScanCalls, 3);
      expect(gatedController.isScanning, isFalse);
    });
  });

  group('includeUnnamed', () {
    PrintlyDevice unnamed(String address, ConnectionType transport) =>
        PrintlyDevice(
          address: address,
          availableTransports: <ConnectionType>{transport},
        );

    test('defaults to false and is passed through to the platform on every '
        'round, including the classicFirst fallback', () async {
      await controller.startScan(timeout: const Duration(milliseconds: 20));
      expect(platform.includeUnnamedCalls, <bool>[false]);
      await controller.stopScan();

      await controller.startScan(includeUnnamed: true);
      expect(platform.includeUnnamedCalls, <bool>[false, true]);
      await controller.stopScan();

      // classicFirst with nothing named: the BLE fallback round must carry
      // the same includeUnnamed the caller chose for the scan.
      await controller.startScan(
        timeout: const Duration(milliseconds: 20),
        strategy: ScanStrategy.classicFirst,
        includeUnnamed: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(platform.includeUnnamedCalls, <bool>[false, true, true, true]);
    });

    test('by default a nameless BLE sighting is dropped at the Dart layer '
        'too (defense in depth over the native filter)', () async {
      await controller.startScan();
      platform.emit(unnamed('AA:BB', ConnectionType.ble));
      await pumpEventQueue();
      expect(controller.currentDevices, isEmpty);
    });

    test('includeUnnamed: true lets nameless BLE sightings through', () async {
      await controller.startScan(includeUnnamed: true);
      platform.emit(unnamed('AA:BB', ConnectionType.ble));
      await pumpEventQueue();
      expect(controller.currentDevices, hasLength(1));
    });

    test('a nameless BLE re-sighting of an already-known device still '
        'merges — real peripherals alternate named/nameless frames', () async {
      await controller.startScan();
      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          name: 'PTP-II',
          rssi: -70,
          availableTransports: <ConnectionType>{ConnectionType.ble},
        ),
      );
      await pumpEventQueue();

      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          rssi: -45,
          availableTransports: <ConnectionType>{ConnectionType.ble},
        ),
      );
      await pumpEventQueue();

      final PrintlyDevice merged = controller.currentDevices.single;
      expect(merged.name, 'PTP-II');
      expect(merged.rssi, -45, reason: 'the RSSI refresh must not be dropped');
    });

    test('a nameless CLASSIC sighting is never dropped — inquiry may report '
        'the name in a later follow-up broadcast', () async {
      await controller.startScan();
      platform.emit(unnamed('AA:BB', ConnectionType.classic));
      await pumpEventQueue();
      expect(controller.currentDevices, hasLength(1));

      // The late name lands and merges into the same record.
      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          name: 'PTP-II',
          availableTransports: <ConnectionType>{ConnectionType.classic},
        ),
      );
      await pumpEventQueue();
      expect(controller.currentDevices.single.name, 'PTP-II');
    });
  });

  group('meaningful-change emissions (field perf finding)', () {
    // In a 140-device environment every re-advertisement (usually only the
    // RSSI moved) re-emitted the full list 4x/second, forcing consumers to
    // write their own diff just to silence state churn.
    test('an RSSI-only re-advertisement does not re-emit the list, but the '
        'snapshot still refreshes', () async {
      await controller.startScan();
      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          name: 'PTP-II',
          rssi: -70,
          availableTransports: <ConnectionType>{ConnectionType.ble},
        ),
      );
      await pumpEventQueue();

      final List<List<PrintlyDevice>> emissions = <List<PrintlyDevice>>[];
      final StreamSubscription<List<PrintlyDevice>> sub = controller
          .devicesStream
          .listen(emissions.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();
      final int baseline = emissions.length;

      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          name: 'PTP-II',
          rssi: -42,
          availableTransports: <ConnectionType>{ConnectionType.ble},
        ),
      );
      await pumpEventQueue();

      expect(emissions.length, baseline, reason: 'only the RSSI moved');
      expect(
        controller.currentDevices.single.rssi,
        -42,
        reason: 'the synchronous snapshot must stay live',
      );
    });

    test('a meaningful change (seenInScan flip, new transport, new device) '
        'still emits', () async {
      await controller.startScan();
      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          name: 'PTP-II',
          isBonded: true,
          seenInScan: false,
          availableTransports: <ConnectionType>{ConnectionType.classic},
        ),
      );
      await pumpEventQueue();

      final List<List<PrintlyDevice>> emissions = <List<PrintlyDevice>>[];
      final StreamSubscription<List<PrintlyDevice>> sub = controller
          .devicesStream
          .listen(emissions.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();
      final int baseline = emissions.length;

      // Bonded seed confirmed by a real sighting: seenInScan flips.
      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          name: 'PTP-II',
          isBonded: true,
          availableTransports: <ConnectionType>{ConnectionType.classic},
        ),
      );
      await pumpEventQueue();
      expect(emissions.length, baseline + 1, reason: 'seenInScan flipped');

      // Dual-mode radio: BLE transport joins the record.
      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          name: 'PTP-II',
          availableTransports: <ConnectionType>{ConnectionType.ble},
        ),
      );
      await pumpEventQueue();
      expect(emissions.length, baseline + 2, reason: 'transport set grew');

      platform.emit(
        PrintlyDevice(
          address: 'CC:DD',
          name: 'Second printer',
          availableTransports: <ConnectionType>{ConnectionType.ble},
        ),
      );
      await pumpEventQueue();
      expect(emissions.length, baseline + 3, reason: 'new device');
    });
  });

  group('post-stop late results (field bug)', () {
    // Android's BluetoothLeScanner.stopScan() is asynchronous: results
    // buffered on the event channel keep arriving AFTER the controller has
    // published `isScanning: false`. Measured in the field: the list kept
    // growing from 115 to 141 entries after "scan finished" was shown.
    test('a result arriving after stopScan completed is dropped — the list '
        'and the stream stay frozen', () async {
      await controller.startScan();
      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          name: 'PTP-II',
          availableTransports: <ConnectionType>{ConnectionType.ble},
        ),
      );
      await pumpEventQueue();
      expect(controller.currentDevices, hasLength(1));

      final List<List<PrintlyDevice>> emissions = <List<PrintlyDevice>>[];
      final StreamSubscription<List<PrintlyDevice>> sub = controller
          .devicesStream
          .listen(emissions.add);
      addTearDown(sub.cancel);

      await controller.stopScan();
      await pumpEventQueue();
      final int emissionsAtStop = emissions.length;

      // The late, buffered native result lands after the final flush.
      platform.emit(
        PrintlyDevice(
          address: 'CC:DD',
          name: 'Late arrival',
          availableTransports: <ConnectionType>{ConnectionType.ble},
        ),
      );
      await pumpEventQueue();

      expect(
        controller.currentDevices,
        hasLength(1),
        reason: 'a result after stop must not join the list',
      );
      expect(
        emissions.length,
        emissionsAtStop,
        reason: 'devicesStream must stay silent once the scan has stopped',
      );
    });

    test('results arriving while the stop is still in flight ARE accepted '
        'and included in the final flush', () async {
      await controller.startScan();
      platform.emit(
        PrintlyDevice(
          address: 'AA:BB',
          name: 'PTP-II',
          availableTransports: <ConnectionType>{ConnectionType.ble},
        ),
      );
      await pumpEventQueue();

      // Park the native stop on a gate: the scan is genuinely still running
      // while the platform processes the stop request.
      platform.stopCompleter = Completer<void>();
      final Future<void> stopping = controller.stopScan();
      await pumpEventQueue();
      expect(controller.isScanning, isTrue);

      platform.emit(
        PrintlyDevice(
          address: 'CC:DD',
          name: 'Mid-stop arrival',
          availableTransports: <ConnectionType>{ConnectionType.ble},
        ),
      );
      await pumpEventQueue();

      platform.stopCompleter!.complete();
      await stopping;

      expect(
        controller.currentDevices,
        hasLength(2),
        reason: 'a result during a genuinely-running scan is still current',
      );
    });
  });
}

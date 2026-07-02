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
  Completer<void>? startCompleter;
  Object? startError;

  @override
  Stream<PrintlyDevice> get scanResults => _resultsController.stream;

  @override
  Future<void> startScan({required Set<ConnectionType> types}) async {
    startScanCalls++;
    lastTypes = types;
    if (startCompleter != null) await startCompleter!.future;
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
    Duration? timeout,
  }) async {}

  @override
  Future<void> disconnect({required PrintlyDevice device}) async {}

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
        const PrintlyDevice(
          address: 'AA:BB',
          type: ConnectionType.ble,
          rssi: -60,
        ),
      );
      platform.emit(
        const PrintlyDevice(
          address: 'AA:BB',
          type: ConnectionType.ble,
          name: 'Printer',
          rssi: -50,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.currentDevices, hasLength(1));
      expect(controller.currentDevices.first.name, 'Printer');
      expect(controller.currentDevices.first.rssi, -50);
    });

    test('same address on different transports yields two entries', () async {
      await controller.startScan();
      platform.emit(
        const PrintlyDevice(address: 'AA:BB', type: ConnectionType.classic),
      );
      platform.emit(
        const PrintlyDevice(address: 'AA:BB', type: ConnectionType.ble),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.currentDevices, hasLength(2));
    });

    test('keeps existing name when a later advertisement omits it', () async {
      await controller.startScan();
      platform.emit(
        const PrintlyDevice(
          address: 'AA:BB',
          type: ConnectionType.ble,
          name: 'Printer',
          rssi: -55,
        ),
      );
      platform.emit(
        const PrintlyDevice(
          address: 'AA:BB',
          type: ConnectionType.ble,
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
        const PrintlyDevice(address: 'AA:BB', type: ConnectionType.ble),
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
        const PrintlyDevice(address: 'AA:BB', type: ConnectionType.ble),
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
        platform.emit(PrintlyDevice(address: 'D$i', type: ConnectionType.ble));
      }
      await Future<void>.delayed(const Duration(milliseconds: 90));

      // All 10 devices land, but the burst collapses to a single update.
      expect(lengths.last, 10);
      expect(lengths.length, lessThan(5));

      await sub.cancel();
      await coalesced.dispose();
    });
  });
}

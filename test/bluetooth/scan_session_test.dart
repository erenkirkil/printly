import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:printly/printly.dart';
import 'package:printly/src/bluetooth/scan_controller.dart';
import 'package:printly/src/bluetooth/scan_session.dart';
import 'package:printly/src/platform/printly_platform_interface.dart';

/// Reuses the fake-platform pattern from scan_controller_test.dart: a
/// minimal [PrintlyPlatform] fake that lets tests emit discoveries and count
/// native start/stop calls without a real method channel.
class _FakePlatform extends PrintlyPlatform with MockPlatformInterfaceMixin {
  final StreamController<PrintlyDevice> _resultsController =
      StreamController<PrintlyDevice>.broadcast();

  int startScanCalls = 0;
  int stopScanCalls = 0;

  @override
  Stream<PrintlyDevice> get scanResults => _resultsController.stream;

  @override
  Future<void> startScan({required Set<ConnectionType> types}) async {
    startScanCalls++;
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

PrintlyDevice _device(String address) => PrintlyDevice(
  address: address,
  availableTransports: <ConnectionType>{ConnectionType.ble},
);

void main() {
  late _FakePlatform platform;
  late ScanController controller;

  setUp(() {
    platform = _FakePlatform();
    controller = ScanController(
      platform: platform,
      emitInterval: Duration.zero,
    );
  });

  tearDown(() async {
    await controller.dispose();
    await platform.close();
  });

  PrintlyScanSession newSession() => createScanSession(
    controller: controller,
    resolveDefaultTimeout: () => const Duration(days: 1),
  );

  group('no stale replay', () {
    test('(a) 42 devices accumulated from a previous scan: a fresh session '
        'never observes the stale list, only the fresh empty reset', () async {
      // Accumulate 42 devices in the SHARED controller from a "previous
      // visit" scan, then stop.
      await controller.startScan();
      for (int i = 0; i < 42; i++) {
        platform.emit(_device('D$i'));
      }
      await pumpEventQueue();
      await controller.stopScan();
      expect(controller.currentDevices, hasLength(42));

      final PrintlyScanSession session = newSession();
      final List<List<PrintlyDevice>> emissions = <List<PrintlyDevice>>[];
      final StreamSubscription<List<PrintlyDevice>> sub = session.devices
          .listen(emissions.add);
      addTearDown(sub.cancel);

      await session.start();
      await pumpEventQueue();

      // The seeded [] plus the fresh startScan() reset — never the stale
      // 42-device list.
      expect(emissions.every((List<PrintlyDevice> l) => l.isEmpty), isTrue);
      expect(session.currentDevices, isEmpty);

      await session.dispose();
    });

    test('(b) controller mid-scan with isScanning true: a fresh, un-started '
        "session's isScanning stays false until its own start()", () async {
      unawaited(controller.startScan(timeout: const Duration(days: 1)));
      await pumpEventQueue();
      expect(controller.isScanning, isTrue);

      final PrintlyScanSession session = newSession();
      // No start() yet — must not reflect the controller's live true.
      expect(session.currentDevices, isEmpty);
      final bool firstIsScanning = await session.isScanning.first;
      expect(firstIsScanning, isFalse);

      await session.start();
      await pumpEventQueue();
      expect(session.currentDevices, isEmpty);

      await session.dispose();
    });
  });

  group('start() forwards discoveries', () {
    test(
      '(c) after start(), controller discoveries flow into the session',
      () async {
        final PrintlyScanSession session = newSession();
        await session.start();
        await pumpEventQueue();

        platform.emit(_device('AA:BB'));
        await pumpEventQueue();

        expect(session.currentDevices, hasLength(1));
        expect(session.currentDevices.single.address, 'AA:BB');

        await session.dispose();
      },
    );
  });

  group('stop() ref-counting', () {
    test('(d) two active sessions: the first stop() does not reach the '
        'platform; the second does', () async {
      final PrintlyScanSession sessionA = newSession();
      final PrintlyScanSession sessionB = newSession();

      await sessionA.start();
      await sessionB.start();
      // controller.startScan() is itself re-entrancy-safe: sessionB's
      // start() while already scanning is a no-op on the native side.
      expect(platform.startScanCalls, 1);

      await sessionA.stop();
      expect(platform.stopScanCalls, 0);
      expect(controller.isScanning, isTrue);

      await sessionB.stop();
      expect(platform.stopScanCalls, 1);
      expect(controller.isScanning, isFalse);

      await sessionA.dispose();
      await sessionB.dispose();
    });
  });

  group('dispose()', () {
    test('(e) dispose() is idempotent; start() after dispose() throws '
        'StateError', () async {
      final PrintlyScanSession session = newSession();
      await session.start();

      await session.dispose();
      await session.dispose(); // must not throw a second time

      // start() is `async`, so a synchronous throw inside it surfaces as
      // a rejected Future, not a synchronous exception — assert on the
      // Future itself, not a wrapping closure (matches the
      // `expectLater(controller.startScan(), throwsA(...))` idiom used in
      // scan_controller_test.dart).
      await expectLater(session.start(), throwsStateError);
    });

    test(
      "(e) dispose() while active releases this session's ref-count share",
      () async {
        final PrintlyScanSession sessionA = newSession();
        final PrintlyScanSession sessionB = newSession();

        await sessionA.start();
        await sessionB.start();

        // sessionA disposes without ever calling stop() explicitly — the
        // ref-count must still be released, so the LAST remaining session's
        // stop() is the one that reaches the platform.
        await sessionA.dispose();
        expect(platform.stopScanCalls, 0);
        expect(controller.isScanning, isTrue);

        await sessionB.stop();
        expect(platform.stopScanCalls, 1);
        expect(controller.isScanning, isFalse);

        await sessionB.dispose();
      },
    );
  });

  group('facade default timeout wiring', () {
    test('start() with no explicit timeout applies the resolver value, not '
        'kDefaultScanTimeout', () async {
      final PrintlyScanSession session = createScanSession(
        controller: controller,
        resolveDefaultTimeout: () => const Duration(milliseconds: 30),
      );
      await session.start();
      expect(controller.isScanning, isTrue);

      // If the resolver were ignored in favour of kDefaultScanTimeout
      // (10 s), the scan would still be running here.
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(controller.isScanning, isFalse);
      expect(platform.stopScanCalls, 1);

      await session.dispose();
    });
  });
}

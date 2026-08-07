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
  Future<void> startScan({
    required Set<ConnectionType> types,
    bool includeUnnamed = false,
  }) async {
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

// Named: the controller's default includeUnnamed=false drops unknown
// nameless BLE sightings, and these tests are about session replay
// semantics, not the unnamed filter.
PrintlyDevice _device(String address) => PrintlyDevice(
  address: address,
  name: 'Printer $address',
  availableTransports: <ConnectionType>{ConnectionType.ble},
);

void main() {
  late _FakePlatform platform;
  late ScanController controller;
  late ScanSessionRegistry registry;

  setUp(() {
    platform = _FakePlatform();
    controller = ScanController(
      platform: platform,
      emitInterval: Duration.zero,
    );
    // A fresh registry per test — this is exactly what fixes the old
    // static-Set test isolation problem: each test's sessions ref-count
    // against their own registry, never a process-wide one shared (and
    // polluted) across every other test in the suite.
    registry = ScanSessionRegistry();
  });

  tearDown(() async {
    await controller.dispose();
    await platform.close();
  });

  PrintlyScanSession newSession() => createScanSession(
    controller: controller,
    registry: registry,
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

    test('(b) controller mid-scan with 3 devices already found: a fresh, '
        "un-started session sees nothing, then joining via start() "
        'delivers the 3 live devices and isScanning true as its first '
        'emissions', () async {
      unawaited(controller.startScan(timeout: const Duration(days: 1)));
      await pumpEventQueue();
      platform.emit(_device('J0'));
      platform.emit(_device('J1'));
      platform.emit(_device('J2'));
      await pumpEventQueue();
      expect(controller.isScanning, isTrue);
      expect(controller.currentDevices, hasLength(3));

      final PrintlyScanSession session = newSession();
      final List<List<PrintlyDevice>> deviceEmissions = <List<PrintlyDevice>>[];
      final List<bool> scanningEmissions = <bool>[];
      final StreamSubscription<List<PrintlyDevice>> devicesSub = session.devices
          .listen(deviceEmissions.add);
      final StreamSubscription<bool> scanningSub = session.isScanning.listen(
        scanningEmissions.add,
      );
      addTearDown(devicesSub.cancel);
      addTearDown(scanningSub.cancel);
      await pumpEventQueue();

      // No start() yet — must not reflect the controller's live state: only
      // the session's own seeded empty/false.
      expect(session.currentDevices, isEmpty);
      expect(deviceEmissions, <List<PrintlyDevice>>[const <PrintlyDevice>[]]);
      expect(scanningEmissions, <bool>[false]);

      await session.start();
      await pumpEventQueue();

      // Joining a live scan delivers its genuinely-current finds (not a
      // stale replay — the scan is still running) as this session's first
      // real emission, plus isScanning flipping true.
      expect(session.currentDevices, hasLength(3));
      expect(
        deviceEmissions.last.map((PrintlyDevice d) => d.address).toSet(),
        <String>{'J0', 'J1', 'J2'},
      );
      expect(scanningEmissions, <bool>[false, true]);

      await session.dispose();
    });

    test('(pending-stop window) a stop in flight when start() is called: '
        'the stale pre-stop list never reaches the session, only what is '
        'discovered after the reset that follows', () async {
      await controller.startScan(timeout: const Duration(days: 1));
      for (int i = 0; i < 42; i++) {
        platform.emit(_device('S$i'));
      }
      await pumpEventQueue();
      expect(controller.currentDevices, hasLength(42));

      // Fire-and-forget stop, then immediately create+start a session so its
      // startScan() chains behind the still-in-flight stop.
      unawaited(controller.stopScan());
      final PrintlyScanSession session = newSession();
      final List<List<PrintlyDevice>> emissions = <List<PrintlyDevice>>[];
      final StreamSubscription<List<PrintlyDevice>> sub = session.devices
          .listen(emissions.add);
      addTearDown(sub.cancel);

      final Future<void> startFuture = session.start();
      await pumpEventQueue();
      await startFuture;
      await pumpEventQueue();

      // Never observed the 42 stale devices at any point.
      for (final List<PrintlyDevice> emission in emissions) {
        expect(emission, hasLength(lessThan(42)));
      }
      expect(session.currentDevices, isEmpty);

      // Post-reset discoveries flow normally once armed.
      platform.emit(_device('FRESH'));
      await pumpEventQueue();
      expect(session.currentDevices, hasLength(1));
      expect(session.currentDevices.single.address, 'FRESH');

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
        registry: registry,
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

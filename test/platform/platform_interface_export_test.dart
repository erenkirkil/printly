// This file deliberately imports ONLY the public barrel — no
// `package:printly/src/…` anywhere. That restriction is the test: it is
// exactly what a consumer can write, and it stops compiling the moment
// `PrintlyPlatform` is no longer reachable from `package:printly/printly.dart`.
//
// Before the export existed, an app that wanted to test its own logic against
// printly had two bad options: reach into `src/` and trip the
// `implementation_imports` lint, or stub the raw `MethodChannel('printly')`
// and hard-code wire strings and codes in its test file. The second option
// fails silently — a wire change makes such a stub measure the wrong thing
// rather than fail — which is why the interface is public API now.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:printly/printly.dart';

/// A consumer-shaped fake: only the members under test are overridden, the
/// rest keep the interface's `UnimplementedError` bodies.
class _ConsumerFake extends PrintlyPlatform with MockPlatformInterfaceMixin {
  final StreamController<BluetoothAdapterState> adapter =
      StreamController<BluetoothAdapterState>.broadcast();
  final StreamController<PrintlyConnectionEvent> events =
      StreamController<PrintlyConnectionEvent>.broadcast();

  int startScanCalls = 0;
  Set<ConnectionType>? lastScanTypes;
  bool locationServiceEnabled = true;

  @override
  Stream<BluetoothAdapterState> get adapterState => adapter.stream;

  @override
  Stream<PrintlyConnectionEvent> get connectionEvents => events.stream;

  @override
  Stream<PrintlyDevice> get scanResults => const Stream<PrintlyDevice>.empty();

  @override
  Future<bool> isLocationServiceEnabled() async => locationServiceEnabled;

  @override
  Future<void> startScan({
    required Set<ConnectionType> types,
    bool includeUnnamed = false,
  }) async {
    startScanCalls++;
    lastScanTypes = types;
  }

  @override
  Future<void> stopScan() async {}

  Future<void> close() async {
    await adapter.close();
    await events.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _ConsumerFake platform;

  setUp(() {
    platform = _ConsumerFake();
    PrintlyPlatform.instance = platform;
  });

  tearDown(() async {
    await platform.close();
  });

  test('a fake installed through the barrel receives facade calls', () async {
    platform.locationServiceEnabled = false;
    final Printly printly = Printly.forTesting();

    expect(await printly.isLocationServiceEnabled(), isFalse);

    platform.locationServiceEnabled = true;
    expect(await printly.isLocationServiceEnabled(), isTrue);
  });

  test('adapter state arrives as an enum, not as a wire integer', () async {
    final Printly printly = Printly.forTesting();
    final Future<BluetoothAdapterState> first = printly.adapterState.firstWhere(
      (BluetoothAdapterState s) => s == BluetoothAdapterState.poweredOn,
    );

    // The consumer's own test used to push the wire code `5` into a mocked
    // EventChannel. Through the interface it pushes the enum instead, so a
    // renumbering on the wire cannot silently change what the test asserts.
    platform.adapter.add(BluetoothAdapterState.poweredOn);

    expect(await first, BluetoothAdapterState.poweredOn);
  });

  test('a scan started through the facade reaches the fake', () async {
    final Printly printly = Printly.forTesting();

    await printly.startScan(timeout: const Duration(milliseconds: 1));

    expect(platform.startScanCalls, 1);
    expect(platform.lastScanTypes, isNotEmpty);
  });
}

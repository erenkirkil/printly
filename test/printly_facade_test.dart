// The last-device persistence cluster is deprecated (removal lands in
// v1.0.0) but must stay covered until it is actually deleted.
// ignore_for_file: deprecated_member_use_from_same_package

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:printly/printly.dart';
import 'package:printly/src/bluetooth/connection_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePlatform extends PrintlyPlatform with MockPlatformInterfaceMixin {
  final StreamController<PrintlyConnectionEvent> events =
      StreamController<PrintlyConnectionEvent>.broadcast();
  final StreamController<BluetoothAdapterState> adapter =
      StreamController<BluetoothAdapterState>.broadcast();

  int connectCalls = 0;
  final List<PrintlyDevice> connectDevices = <PrintlyDevice>[];
  int requestEnableBluetoothCalls = 0;
  bool requestEnableBluetoothResult = true;
  int isLocationServiceEnabledCalls = 0;
  bool isLocationServiceEnabledResult = true;
  int openLocationSettingsCalls = 0;
  bool openLocationSettingsResult = true;
  int writeCalls = 0;
  ConnectionType? lastWriteTransport;

  @override
  Stream<PrintlyConnectionEvent> get connectionEvents => events.stream;

  @override
  Stream<BluetoothAdapterState> get adapterState => adapter.stream;

  @override
  Future<void> connect({
    required PrintlyDevice device,
    required ConnectionType transport,
    Duration? timeout,
  }) async {
    connectCalls++;
    connectDevices.add(device);
  }

  @override
  Future<void> disconnect({
    required PrintlyDevice device,
    required ConnectionType transport,
  }) async {}

  @override
  Stream<PrintlyDevice> get scanResults => const Stream<PrintlyDevice>.empty();

  @override
  Future<void> startScan({
    required Set<ConnectionType> types,
    bool includeUnnamed = false,
  }) async {}

  @override
  Future<void> stopScan() async {}

  @override
  Future<bool> requestEnableBluetooth() async {
    requestEnableBluetoothCalls++;
    return requestEnableBluetoothResult;
  }

  @override
  Future<bool> isLocationServiceEnabled() async {
    isLocationServiceEnabledCalls++;
    return isLocationServiceEnabledResult;
  }

  @override
  Future<bool> openLocationSettings() async {
    openLocationSettingsCalls++;
    return openLocationSettingsResult;
  }

  @override
  Future<void> write({
    required PrintlyDevice device,
    required ConnectionType transport,
    required Uint8List bytes,
  }) async {
    writeCalls++;
    lastWriteTransport = transport;
  }

  Future<void> close() async {
    await events.close();
    await adapter.close();
  }
}

final PrintlyDevice device = PrintlyDevice(
  address: 'AA:BB:CC:DD:EE:FF',
  availableTransports: <ConnectionType>{ConnectionType.classic},
  name: 'PTP-II',
);

/// A never-connected dual-mode device, used to exercise `print()`'s
/// transport-fallback path (see the `print() transport fallback` group).
final PrintlyDevice dualModeDevice = PrintlyDevice(
  address: '11:22:33:44:55:66',
  availableTransports: <ConnectionType>{
    ConnectionType.classic,
    ConnectionType.ble,
  },
  name: 'Dual-mode printer',
);

const String _deviceKey = 'printly.last_connected_device';
const String _autoReconnectKey = 'printly.auto_reconnect_enabled';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakePlatform platform;

  setUp(() {
    platform = _FakePlatform();
    PrintlyPlatform.instance = platform;
  });

  tearDown(() async {
    await platform.close();
  });

  /// Drives a connect through the facade to the `connected` state.
  Future<void> establish(Printly printly) async {
    final Future<void> f = printly.connect(device);
    await Future<void>.delayed(Duration.zero);
    platform.events.add(
      PrintlyConnectionEvent(device: device, state: ConnectionState.connected),
    );
    await f;
  }

  group('last-device persistence', () {
    test('a plain connect() persists the device without any store-touching '
        'API being called first (regression)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final Printly printly = Printly.forTesting();

      await establish(printly);
      await pumpEventQueue();

      expect(printly.lastConnectedDevice, device);
      // Equality is address-only (C1) — assert availableTransports too.
      expect(
        printly.lastConnectedDevice!.availableTransports,
        device.availableTransports,
      );
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_deviceKey);
      expect(raw, isNotNull);
      expect(
        PrintlyDevice.fromJson(
          (json.decode(raw!) as Map).cast<String, Object?>(),
        ),
        device,
      );
    });

    test('reconnectLastDevice() works on a fresh launch after a plain '
        'connect in the previous session', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _deviceKey: json.encode(device.toJson()),
      });
      final Printly printly = Printly.forTesting();

      final Future<bool> result = printly.reconnectLastDevice();
      await pumpEventQueue();
      platform.events.add(
        PrintlyConnectionEvent(
          device: device,
          state: ConnectionState.connected,
        ),
      );
      expect(await result, isTrue);
      expect(platform.connectDevices, <PrintlyDevice>[device]);
    });

    test('a device connected in this session is not clobbered by the '
        'stale persisted one when the store opens later', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _deviceKey: json.encode(
          PrintlyDevice(
            address: '11:22:33:44:55:66',
            availableTransports: <ConnectionType>{ConnectionType.ble},
            name: 'OLD',
          ).toJson(),
        ),
      });
      final Printly printly = Printly.forTesting();

      await establish(printly);
      await pumpEventQueue();

      expect(printly.lastConnectedDevice, device);
      expect(
        printly.lastConnectedDevice!.availableTransports,
        device.availableTransports,
      );
      await printly.loadLastConnectedDevice();
      expect(printly.lastConnectedDevice, device);
      expect(
        printly.lastConnectedDevice!.availableTransports,
        device.availableTransports,
      );
    });
  });

  group('auto-reconnect restore', () {
    test('a persisted auto-reconnect flag re-arms the adapter listener on '
        'the next launch (regression)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _autoReconnectKey: true,
        _deviceKey: json.encode(device.toJson()),
      });
      final Printly printly = Printly.forTesting();

      // The documented restore path: just load the persisted device.
      final PrintlyDevice? loaded = await printly.loadLastConnectedDevice();
      expect(loaded, device);
      expect(loaded!.availableTransports, device.availableTransports);
      expect(printly.isAutoReconnectEnabled, isTrue);

      // Adapter comes back — the restored flag must act on its own.
      platform.adapter.add(BluetoothAdapterState.poweredOn);
      await pumpEventQueue();
      expect(platform.connectCalls, 1);

      // Resolve the retry so no timer outlives the test.
      platform.events.add(
        PrintlyConnectionEvent(
          device: device,
          state: ConnectionState.connected,
        ),
      );
      await pumpEventQueue();
    });

    test('a persisted false flag does not arm the listener', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _autoReconnectKey: false,
        _deviceKey: json.encode(device.toJson()),
      });
      final Printly printly = Printly.forTesting();

      await printly.loadLastConnectedDevice();
      expect(printly.isAutoReconnectEnabled, isFalse);

      platform.adapter.add(BluetoothAdapterState.poweredOn);
      await pumpEventQueue();
      expect(platform.connectCalls, 0);
    });
  });

  group('requestEnableBluetooth', () {
    test('delegates to the platform and returns its flag', () async {
      final Printly printly = Printly.forTesting();
      platform.requestEnableBluetoothResult = true;

      expect(await printly.requestEnableBluetooth(), isTrue);
      expect(platform.requestEnableBluetoothCalls, 1);
    });

    test('passes through a false (already-on / no-op) result', () async {
      final Printly printly = Printly.forTesting();
      platform.requestEnableBluetoothResult = false;

      expect(await printly.requestEnableBluetooth(), isFalse);
      expect(platform.requestEnableBluetoothCalls, 1);
    });
  });

  group('isLocationServiceEnabled', () {
    test('delegates to the platform and returns its flag', () async {
      final Printly printly = Printly.forTesting();
      platform.isLocationServiceEnabledResult = false;

      expect(await printly.isLocationServiceEnabled(), isFalse);
      expect(platform.isLocationServiceEnabledCalls, 1);
    });
  });

  group('openLocationSettings', () {
    test('delegates to the platform and returns its flag', () async {
      final Printly printly = Printly.forTesting();
      platform.openLocationSettingsResult = true;

      expect(await printly.openLocationSettings(), isTrue);
      expect(platform.openLocationSettingsCalls, 1);
    });
  });

  group('print() transport fallback', () {
    late CapabilityProfile profile;

    setUpAll(() async {
      profile = await CapabilityProfile.load();
    });

    PrintJob job() =>
        PrintJob.fromGenerator(generator: Generator(PaperSize.mm58, profile));

    test('a never-connected device resolves its transport via '
        'resolveTransport() instead of requiring a prior connect()', () async {
      final Printly printly = Printly.forTesting();

      // dualModeDevice has never been passed to connect(), so
      // ConnectionController.transportOf() is null and print() must fall
      // back to ConnectionController.resolveTransport(). The test host is
      // neither iOS nor Android, so the real Platform.isIOS reads false
      // inside resolveTransport and it takes the same "Android" branch
      // exercised directly in connection_controller_test.dart — classic
      // wins for a dual-mode device.
      await printly.print(dualModeDevice, job());

      expect(platform.writeCalls, 1);
      expect(platform.lastWriteTransport, ConnectionType.classic);
      expect(platform.connectCalls, 0); // print() never connects first.
    });

    test(
      'iOS classic-only device: PrintlyUnsupportedException(classicRequiresMfi) '
      'is the error print() would surface as a Future rejection',
      () {
        // Printly.print() resolves the transport with
        // ConnectionController.resolveTransport(device, isIOS: Platform.isIOS)
        // — the real dart:io Platform.isIOS, not an injectable seam
        // (verified: IOOverrides only covers File/Directory/Socket, not
        // Platform). A host-run unit test can therefore never drive print()
        // itself down the iOS branch to observe the wrapping
        // `Future<void>.error(error, stackTrace)` in printly_base.dart's
        // catch clause. What's independently testable — and is tested here
        // — is that resolveTransport (the function print() delegates to)
        // throws exactly PrintlyUnsupportedException(classicRequiresMfi) for
        // a classic-only device under the iOS rule, which is the value that
        // catch clause would forward. See also the "resolveTransport (pure)"
        // group in connection_controller_test.dart for the same contract
        // exercised directly against resolveTransport.
        expect(
          () => ConnectionController.resolveTransport(device, isIOS: true),
          throwsA(
            isA<PrintlyUnsupportedException>().having(
              (PrintlyUnsupportedException e) => e.code,
              'code',
              PrintlyErrorCode.classicRequiresMfi,
            ),
          ),
        );
      },
    );
  });
}

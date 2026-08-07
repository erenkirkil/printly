import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';
import 'package:printly/src/platform/printly_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final MethodChannelPrintly platform = MethodChannelPrintly();
  const MethodChannel methodChannel = MethodChannel(kPrintlyMethodChannelName);
  const MethodChannel adapterStateMethodChannel = MethodChannel(
    kPrintlyAdapterStateEventChannelName,
  );

  const MethodChannel scanResultsMethodChannel = MethodChannel(
    kPrintlyScanResultsEventChannelName,
  );
  const MethodChannel connectionEventsMethodChannel = MethodChannel(
    kPrintlyConnectionEventsChannelName,
  );

  String? invokedMethod;
  List<MethodCall> invocations = <MethodCall>[];

  setUp(() {
    invokedMethod = null;
    invocations = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
          invokedMethod = call.method;
          invocations.add(call);
          switch (call.method) {
            case 'getPlatformVersion':
              return '42';
            case 'getAndroidSdkInt':
              return 31;
            case 'openBluetoothSettings':
              return true;
            case 'requestEnableBluetooth':
              return true;
            case 'isLocationServiceEnabled':
              return false;
            case 'openLocationSettings':
              return true;
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(adapterStateMethodChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(scanResultsMethodChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(connectionEventsMethodChannel, null);
  });

  test('getPlatformVersion delegates to the native channel', () async {
    expect(await platform.getPlatformVersion(), '42');
    expect(invokedMethod, 'getPlatformVersion');
  });

  test('openBluetoothSettings delegates and unwraps the boolean', () async {
    expect(await platform.openBluetoothSettings(), isTrue);
    expect(invokedMethod, 'openBluetoothSettings');
  });

  test('getAndroidSdkInt delegates and unwraps the int', () async {
    expect(await platform.getAndroidSdkInt(), 31);
    expect(invokedMethod, 'getAndroidSdkInt');
  });

  test(
    'requestEnableBluetooth invokes the wire method and returns the flag',
    () async {
      expect(await platform.requestEnableBluetooth(), isTrue);
      expect(invocations.single.method, 'requestEnableBluetooth');
    },
  );

  test('requestEnableBluetooth maps permission_denied to '
      'PrintlyPermissionException', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
          throw PlatformException(
            code: 'permission_denied',
            message: 'bluetooth_connect_required',
          );
        });
    await expectLater(
      platform.requestEnableBluetooth(),
      throwsA(isA<PrintlyPermissionException>()),
    );
  });

  test(
    'isLocationServiceEnabled invokes the wire method and returns the flag',
    () async {
      expect(await platform.isLocationServiceEnabled(), isFalse);
      expect(invocations.single.method, 'isLocationServiceEnabled');
    },
  );

  test(
    'openLocationSettings invokes the wire method and returns the flag',
    () async {
      expect(await platform.openLocationSettings(), isTrue);
      expect(invocations.single.method, 'openLocationSettings');
    },
  );

  test('locationServicesDisabled round-trips through its wire name', () {
    expect(
      PrintlyErrorCode.fromWireName('location_services_disabled'),
      PrintlyErrorCode.locationServicesDisabled,
    );
    expect(
      PrintlyErrorCode.locationServicesDisabled.wireName,
      'location_services_disabled',
    );
  });

  test('adapterState decodes integer events into enum values', () async {
    const MethodCodec codec = StandardMethodCodec();

    Future<void> send(int code) async {
      final ByteData envelope = codec.encodeSuccessEnvelope(code);
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            adapterStateMethodChannel.name,
            envelope,
            (_) {},
          );
    }

    final MethodChannelPrintly freshPlatform = MethodChannelPrintly();
    final Stream<BluetoothAdapterState> stream = freshPlatform.adapterState;
    final List<BluetoothAdapterState> received = <BluetoothAdapterState>[];
    final subscription = stream.listen(received.add);
    // The listen() call above triggers an internal "listen" method invocation
    // on the event channel. Await a microtask so the channel is ready to
    // receive events before we send them.
    await Future<void>.delayed(Duration.zero);

    await send(5);
    await send(4);
    await send(0);
    await Future<void>.delayed(Duration.zero);

    expect(received, <BluetoothAdapterState>[
      BluetoothAdapterState.poweredOn,
      BluetoothAdapterState.poweredOff,
      BluetoothAdapterState.unknown,
    ]);

    await subscription.cancel();
  });

  test('startScan forwards transport wire codes', () async {
    await platform.startScan(
      types: const <ConnectionType>{ConnectionType.classic, ConnectionType.ble},
    );
    expect(invokedMethod, 'startScan');
    final Map<Object?, Object?> args =
        invocations.single.arguments as Map<Object?, Object?>;
    expect(args['types'], <int>[0, 1]);
    expect(
      args['includeUnnamed'],
      isFalse,
      reason: 'the default must reach the native filter explicitly',
    );
  });

  test('startScan forwards includeUnnamed: true', () async {
    await platform.startScan(
      types: const <ConnectionType>{ConnectionType.ble},
      includeUnnamed: true,
    );
    final Map<Object?, Object?> args =
        invocations.single.arguments as Map<Object?, Object?>;
    expect(args['includeUnnamed'], isTrue);
  });

  test('stopScan delegates without arguments', () async {
    await platform.stopScan();
    expect(invokedMethod, 'stopScan');
    expect(invocations.single.arguments, isNull);
  });

  test('scanResults decodes raw map events into PrintlyDevice', () async {
    const MethodCodec codec = StandardMethodCodec();

    Future<void> send(Map<String, Object?> event) async {
      final ByteData envelope = codec.encodeSuccessEnvelope(event);
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            scanResultsMethodChannel.name,
            envelope,
            (_) {},
          );
    }

    final MethodChannelPrintly freshPlatform = MethodChannelPrintly();
    final List<PrintlyDevice> received = <PrintlyDevice>[];
    final subscription = freshPlatform.scanResults.listen(received.add);
    await Future<void>.delayed(Duration.zero);

    await send(<String, Object?>{
      'address': 'AA:BB:CC:DD:EE:FF',
      'type': 1,
      'name': 'Printer',
      'rssi': -55,
      'isBonded': true,
    });
    await send(<String, Object?>{'address': '11:22:33:44:55:66', 'type': 0});
    // Malformed — silently dropped.
    await send(<String, Object?>{'type': 0});
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(2));
    expect(received[0].address, 'AA:BB:CC:DD:EE:FF');
    expect(received[0].availableTransports, <ConnectionType>{
      ConnectionType.ble,
    });
    expect(received[0].name, 'Printer');
    expect(received[0].rssi, -55);
    expect(received[0].isBonded, isTrue);
    expect(received[1].availableTransports, <ConnectionType>{
      ConnectionType.classic,
    });

    await subscription.cancel();
  });

  test('connect forwards device payload, transport, and timeout', () async {
    final PrintlyDevice device = PrintlyDevice(
      address: 'AA:BB',
      availableTransports: <ConnectionType>{ConnectionType.ble},
      name: 'Printer',
    );
    await platform.connect(
      device: device,
      transport: ConnectionType.ble,
      timeout: const Duration(seconds: 5),
    );
    expect(invokedMethod, 'connect');
    final Map<Object?, Object?> args =
        invocations.single.arguments as Map<Object?, Object?>;
    expect(args['timeoutMs'], 5000);
    expect((args['device'] as Map<Object?, Object?>)['address'], 'AA:BB');
    expect(
      (args['device'] as Map<Object?, Object?>)['type'],
      ConnectionType.ble.wireCode,
    );
  });

  test('disconnect forwards device payload and transport', () async {
    final PrintlyDevice device = PrintlyDevice(
      address: 'AA:BB',
      availableTransports: <ConnectionType>{ConnectionType.ble},
    );
    await platform.disconnect(device: device, transport: ConnectionType.ble);
    expect(invokedMethod, 'disconnect');
    final Map<Object?, Object?> args =
        invocations.single.arguments as Map<Object?, Object?>;
    expect((args['device'] as Map<Object?, Object?>)['address'], 'AA:BB');
    expect(
      (args['device'] as Map<Object?, Object?>)['type'],
      ConnectionType.ble.wireCode,
    );
  });

  test('write forwards device payload, transport, and bytes', () async {
    final PrintlyDevice device = PrintlyDevice(
      address: 'AA:BB',
      availableTransports: <ConnectionType>{ConnectionType.classic},
    );
    final Uint8List bytes = Uint8List.fromList(<int>[0x1B, 0x40, 0x41]);
    await platform.write(
      device: device,
      transport: ConnectionType.classic,
      bytes: bytes,
    );
    expect(invokedMethod, 'write');
    final Map<Object?, Object?> args =
        invocations.single.arguments as Map<Object?, Object?>;
    expect((args['device'] as Map<Object?, Object?>)['address'], 'AA:BB');
    expect((args['device'] as Map<Object?, Object?>)['type'], 0);
    // Bytes must travel as a Uint8List (zero-copy typed-data path), not a
    // boxed List<int>.
    expect(args['bytes'], isA<Uint8List>());
    expect(args['bytes'], <int>[0x1B, 0x40, 0x41]);
  });

  test(
    'connect/disconnect/write send the SAME transport type for a dual-mode '
    'device — the native side keys sessions by `type:address`, so a '
    'mismatch across the three calls would silently miss the session',
    () async {
      final PrintlyDevice device = PrintlyDevice(
        address: 'AA:BB',
        availableTransports: <ConnectionType>{
          ConnectionType.classic,
          ConnectionType.ble,
        },
        name: 'Dual',
      );
      await platform.connect(
        device: device,
        transport: ConnectionType.ble,
        timeout: const Duration(seconds: 5),
      );
      await platform.disconnect(device: device, transport: ConnectionType.ble);
      await platform.write(
        device: device,
        transport: ConnectionType.ble,
        bytes: Uint8List.fromList(<int>[1]),
      );

      expect(invocations, hasLength(3));
      expect(invocations[0].method, 'connect');
      expect(invocations[1].method, 'disconnect');
      expect(invocations[2].method, 'write');
      for (final MethodCall call in invocations) {
        final Map<Object?, Object?> args =
            call.arguments as Map<Object?, Object?>;
        final Map<Object?, Object?> deviceMap =
            args['device'] as Map<Object?, Object?>;
        expect(deviceMap['type'], ConnectionType.ble.wireCode);
      }
    },
  );

  group('typed error mapping', () {
    void throwOnInvoke(String code, String? message) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
            throw PlatformException(code: code, message: message);
          });
    }

    final PrintlyDevice device = PrintlyDevice(
      address: 'AA:BB',
      availableTransports: <ConnectionType>{ConnectionType.ble},
    );

    test('startScan maps the specific message over the generic code', () async {
      throwOnInvoke('start_scan_failed', 'bluetooth_not_powered_on');
      await expectLater(
        platform.startScan(types: const <ConnectionType>{ConnectionType.ble}),
        throwsA(
          isA<PrintlyScanException>().having(
            (PrintlyScanException e) => e.code,
            'code',
            PrintlyErrorCode.bluetoothNotPoweredOn,
          ),
        ),
      );
    });

    test(
      'startScan surfaces location_services_disabled as a typed scan error',
      () async {
        throwOnInvoke('start_scan_failed', 'location_services_disabled');
        await expectLater(
          platform.startScan(
            types: const <ConnectionType>{ConnectionType.classic},
          ),
          throwsA(
            isA<PrintlyScanException>().having(
              (PrintlyScanException e) => e.code,
              'code',
              PrintlyErrorCode.locationServicesDisabled,
            ),
          ),
        );
      },
    );

    test('permission failures map to PrintlyPermissionException', () async {
      throwOnInvoke('permission_denied', 'bluetooth_scan_denied');
      await expectLater(
        platform.startScan(types: const <ConnectionType>{ConnectionType.ble}),
        throwsA(isA<PrintlyPermissionException>()),
      );
    });

    test('write maps write_timeout even when the code is generic', () async {
      throwOnInvoke('write_failed', 'write_timeout');
      await expectLater(
        platform.write(
          device: device,
          transport: ConnectionType.ble,
          bytes: Uint8List.fromList(<int>[1]),
        ),
        throwsA(
          isA<PrintlyWriteException>().having(
            (PrintlyWriteException e) => e.code,
            'code',
            PrintlyErrorCode.writeTimeout,
          ),
        ),
      );
    });

    test('unsupported-platform rejections map to '
        'PrintlyUnsupportedException', () async {
      throwOnInvoke('unsupported_platform', 'ios write ships in sprint 6');
      await expectLater(
        platform.write(
          device: device,
          transport: ConnectionType.ble,
          bytes: Uint8List.fromList(<int>[1]),
        ),
        throwsA(isA<PrintlyUnsupportedException>()),
      );
    });

    test('unclassifiable errors keep the raw message under unknown', () async {
      throwOnInvoke('something_new', 'exotic native failure');
      await expectLater(
        platform.connect(device: device, transport: ConnectionType.ble),
        throwsA(
          isA<PrintlyConnectionException>()
              .having(
                (PrintlyConnectionException e) => e.code,
                'code',
                PrintlyErrorCode.unknown,
              )
              .having(
                (PrintlyConnectionException e) => e.message,
                'message',
                'exotic native failure',
              ),
        ),
      );
    });
  });

  test('connectionEvents decode raw map payloads', () async {
    const MethodCodec codec = StandardMethodCodec();

    Future<void> send(Map<String, Object?> event) async {
      final ByteData envelope = codec.encodeSuccessEnvelope(event);
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            connectionEventsMethodChannel.name,
            envelope,
            (_) {},
          );
    }

    final MethodChannelPrintly freshPlatform = MethodChannelPrintly();
    final List<PrintlyConnectionEvent> received = <PrintlyConnectionEvent>[];
    final subscription = freshPlatform.connectionEvents.listen(received.add);
    await Future<void>.delayed(Duration.zero);

    await send(<String, Object?>{
      'device': <String, Object?>{'address': 'AA:BB', 'type': 1},
      'state': 2,
    });
    await send(<String, Object?>{
      'device': <String, Object?>{'address': 'AA:BB', 'type': 1},
      'state': 5,
      'failureReason': 'timeout',
    });
    // Malformed — silently dropped.
    await send(<String, Object?>{'state': 2});
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(2));
    expect(received[0].state, ConnectionState.connected);
    expect(received[1].state, ConnectionState.error);
    expect(received[1].failureReason, 'timeout');

    await subscription.cancel();
  });
}

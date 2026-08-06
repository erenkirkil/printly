import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:printly/printly.dart';
import 'package:printly/src/core/bluetooth_permission_set.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(
    'flutter.baseflow.com/permissions/methods',
  );
  late List<String> calls;
  // permission_handler wire statuses: denied=0, granted=1.
  int statusToReturn = 1;

  setUp(() {
    calls = <String>[];
    statusToReturn = 1;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call.method);
          if (call.method == 'checkPermissionStatus') return statusToReturn;
          if (call.method == 'requestPermissions') {
            final List<dynamic> perms = call.arguments as List<dynamic>;
            return <dynamic, dynamic>{
              for (final dynamic p in perms) p: statusToReturn,
            };
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('requiredBluetoothPermissions', () {
    test('Android 12+ asks only the two runtime Bluetooth permissions', () {
      expect(
        requiredBluetoothPermissions(isAndroid: true, sdkInt: 31),
        <ph.Permission>[
          ph.Permission.bluetoothScan,
          ph.Permission.bluetoothConnect,
        ],
      );
    });

    test('Android 11 and below adds location', () {
      expect(
        requiredBluetoothPermissions(isAndroid: true, sdkInt: 30),
        <ph.Permission>[
          ph.Permission.bluetooth,
          ph.Permission.locationWhenInUse,
        ],
      );
    });

    test('iOS asks only bluetooth', () {
      expect(
        requiredBluetoothPermissions(isAndroid: false, sdkInt: 0),
        <ph.Permission>[ph.Permission.bluetooth],
      );
    });
  });

  group('checkPermissions', () {
    test(
      'reads status without ever requesting (the actual contract)',
      () async {
        final PrintlyPermissionStatus status = await Printly.forTesting()
            .checkPermissions();
        expect(status, PrintlyPermissionStatus.granted);
        expect(calls, isNotEmpty);
        expect(calls, isNot(contains('requestPermissions')));
      },
    );

    test('propagates a denied status', () async {
      statusToReturn = 0;
      final PrintlyPermissionStatus status = await Printly.forTesting()
          .checkPermissions();
      expect(status, PrintlyPermissionStatus.denied);
    });
  });
}

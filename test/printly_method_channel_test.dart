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

  String? invokedMethod;

  setUp(() {
    invokedMethod = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
          invokedMethod = call.method;
          switch (call.method) {
            case 'getPlatformVersion':
              return '42';
            case 'openBluetoothSettings':
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
  });

  test('getPlatformVersion delegates to the native channel', () async {
    expect(await platform.getPlatformVersion(), '42');
    expect(invokedMethod, 'getPlatformVersion');
  });

  test('openBluetoothSettings delegates and unwraps the boolean', () async {
    expect(await platform.openBluetoothSettings(), isTrue);
    expect(invokedMethod, 'openBluetoothSettings');
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
}

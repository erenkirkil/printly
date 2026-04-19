import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:printly/printly.dart';
import 'package:printly/src/platform/printly_method_channel.dart';
import 'package:printly/src/platform/printly_platform_interface.dart';

class _MockPrintlyPlatform extends PrintlyPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<String?> getPlatformVersion() async => '42';

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      const Stream<BluetoothAdapterState>.empty();

  @override
  Future<bool> openBluetoothSettings() async => true;
}

void main() {
  final PrintlyPlatform initialPlatform = PrintlyPlatform.instance;

  test('$MethodChannelPrintly is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelPrintly>());
  });

  test('getPlatformVersion', () async {
    PrintlyPlatform.instance = _MockPrintlyPlatform();
    expect(await Printly.instance.getPlatformVersion(), '42');
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';
import 'package:printly/printly_platform_interface.dart';
import 'package:printly/printly_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockPrintlyPlatform
    with MockPlatformInterfaceMixin
    implements PrintlyPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final PrintlyPlatform initialPlatform = PrintlyPlatform.instance;

  test('$MethodChannelPrintly is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelPrintly>());
  });

  test('getPlatformVersion', () async {
    Printly printlyPlugin = Printly();
    MockPrintlyPlatform fakePlatform = MockPrintlyPlatform();
    PrintlyPlatform.instance = fakePlatform;

    expect(await printlyPlugin.getPlatformVersion(), '42');
  });
}

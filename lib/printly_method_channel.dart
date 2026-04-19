import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'printly_platform_interface.dart';

/// An implementation of [PrintlyPlatform] that uses method channels.
class MethodChannelPrintly extends PrintlyPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('printly');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}

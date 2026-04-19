import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'printly_method_channel.dart';

abstract class PrintlyPlatform extends PlatformInterface {
  /// Constructs a PrintlyPlatform.
  PrintlyPlatform() : super(token: _token);

  static final Object _token = Object();

  static PrintlyPlatform _instance = MethodChannelPrintly();

  /// The default instance of [PrintlyPlatform] to use.
  ///
  /// Defaults to [MethodChannelPrintly].
  static PrintlyPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [PrintlyPlatform] when
  /// they register themselves.
  static set instance(PrintlyPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}

import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'printly_method_channel.dart';

/// The interface that platform-specific implementations of `printly` must
/// extend.
///
/// Platform implementations should extend this class rather than implement
/// it, so additions to the interface are not breaking changes for existing
/// subclasses.
abstract class PrintlyPlatform extends PlatformInterface {
  /// Constructs a [PrintlyPlatform].
  PrintlyPlatform() : super(token: _token);

  static final Object _token = Object();

  static PrintlyPlatform _instance = MethodChannelPrintly();

  /// The default instance of [PrintlyPlatform] to use.
  ///
  /// Defaults to [MethodChannelPrintly].
  static PrintlyPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [PrintlyPlatform] when they
  /// register themselves.
  static set instance(PrintlyPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Returns the native platform version string (e.g. `Android 14`, `iOS 17.2`).
  Future<String?> getPlatformVersion() {
    throw UnimplementedError('getPlatformVersion() has not been implemented.');
  }
}

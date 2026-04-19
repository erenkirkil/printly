
import 'printly_platform_interface.dart';

class Printly {
  Future<String?> getPlatformVersion() {
    return PrintlyPlatform.instance.getPlatformVersion();
  }
}

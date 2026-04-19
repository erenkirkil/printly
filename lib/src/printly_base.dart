import 'platform/printly_platform_interface.dart';

/// Entry point for the `printly` SDK.
///
/// Access the SDK through the [Printly.instance] singleton. Public methods
/// are added progressively across sprints (see `docs/sprints.md`). Calls to
/// not-yet-implemented APIs throw [UnimplementedError].
class Printly {
  Printly._();

  /// The shared [Printly] singleton.
  static final Printly instance = Printly._();

  /// Returns the underlying native platform version string.
  ///
  /// Intended as a smoke test during Sprint 1. Will be replaced by real
  /// capability queries in later sprints.
  Future<String?> getPlatformVersion() {
    return PrintlyPlatform.instance.getPlatformVersion();
  }
}

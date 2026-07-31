import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:printly/printly.dart';

/// Cross-tab settings: the selected paper width (every print job reads it) and
/// the platform version banner.
///
/// Injected into [PrintViewModel] rather than duplicated, so switching to 80 mm
/// on the Settings tab immediately changes what the Print tab produces.
class SettingsViewModel extends ChangeNotifier {
  PrintlyPaperWidth _paperWidth = PrintlyPaperWidth.mm58;
  String _platformVersion = 'Unknown';

  PrintlyPaperWidth get paperWidth => _paperWidth;
  String get platformVersion => _platformVersion;

  set paperWidth(PrintlyPaperWidth value) {
    if (_paperWidth == value) return;
    _paperWidth = value;
    notifyListeners();
  }

  /// Kicks off the async platform-version lookup.
  ///
  /// Deliberately not in the constructor: the widget test pumps the app once
  /// with no method-channel handler installed, and a constructor that reached
  /// for the platform would make construction itself fallible.
  Future<void> start() async {
    String version;
    try {
      version =
          await Printly.instance.getPlatformVersion() ??
          'Unknown platform version';
    } on PlatformException {
      version = 'Failed to get platform version.';
    }
    _platformVersion = version;
    notifyListeners();
  }
}

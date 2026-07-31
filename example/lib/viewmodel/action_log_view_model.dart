import 'package:flutter/foundation.dart';

import '../model/action_log.dart';

/// Holds the outcome of the most recent action.
///
/// Shared by every other view model so the status strip shows the last result
/// regardless of which tab produced it — the single-page playground used to
/// lose that context whenever a section scrolled out of view.
class ActionLogViewModel extends ChangeNotifier {
  ActionLog? _last;

  /// The most recent action outcome, or null before anything has run.
  ActionLog? get last => _last;

  void success(String message) {
    _last = ActionLog(message: message, isError: false);
    notifyListeners();
  }

  void failure(String message) {
    _last = ActionLog(message: message, isError: true);
    notifyListeners();
  }
}

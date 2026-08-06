import 'package:flutter/foundation.dart';

import '../model/action_log.dart';

/// Maximum number of entries retained in [ActionLogViewModel.entries].
///
/// A field session can run for hours; without a cap the history would grow
/// unbounded for the lifetime of the app. 50 is generous for a single
/// diagnostics session while keeping the copy-all payload readable.
const int kActionLogHistoryLimit = 50;

/// Holds the outcome of every recent action, not just the last one.
///
/// Shared by every other view model so the status strip shows the last result
/// regardless of which tab produced it — the single-page playground used to
/// lose that context whenever a section scrolled out of view.
///
/// A field tester debugging a hardware failure needs more than the final
/// line: `ScanViewModel.connect()` logs a `connect attempt → …` line
/// immediately followed by a `connect error → …` line, and the attempt line
/// (which carries the target device) used to be overwritten before anyone
/// could read it. Keeping a bounded history lets the tester open the full
/// log, read the typed error code at the tail of a long message, and copy it
/// verbatim into a bug report.
class ActionLogViewModel extends ChangeNotifier {
  /// Newest-first history, capped at [kActionLogHistoryLimit] entries.
  final List<ActionLog> _entries = <ActionLog>[];

  /// Full history, newest entry first.
  List<ActionLog> get entries => List<ActionLog>.unmodifiable(_entries);

  /// The most recent action outcome, or null before anything has run.
  ActionLog? get last => _entries.isEmpty ? null : _entries.first;

  void success(String message) {
    _append(ActionLog(message: message, isError: false, at: DateTime.now()));
  }

  void failure(String message) {
    _append(ActionLog(message: message, isError: true, at: DateTime.now()));
  }

  void _append(ActionLog entry) {
    _entries.insert(0, entry);
    if (_entries.length > kActionLogHistoryLimit) {
      _entries.removeRange(kActionLogHistoryLimit, _entries.length);
    }
    notifyListeners();
  }

  /// Discards the entire history, e.g. after a report has been filed and the
  /// tester wants a clean slate for the next reproduction attempt.
  void clear() {
    _entries.clear();
    notifyListeners();
  }
}

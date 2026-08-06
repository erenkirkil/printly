import 'package:flutter/foundation.dart';

/// The outcome of a playground action, surfaced in the status strip so a
/// failure stays visible after the user switches tabs.
@immutable
class ActionLog {
  const ActionLog({
    required this.message,
    required this.isError,
    required this.at,
  });

  /// Human-readable summary, e.g. `print → ok` or `connect error → …`.
  final String message;

  /// Whether [message] describes a failure; drives the status strip colour.
  final bool isError;

  /// Wall-clock time this entry was created.
  ///
  /// Captured by the view model (not derived later) so the log-history sheet
  /// can show a field tester exactly when a failure happened, which matters
  /// when correlating a report against hardware logs collected separately.
  final DateTime at;
}

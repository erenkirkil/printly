import 'package:flutter/foundation.dart';

/// The outcome of the most recent playground action, surfaced in the status
/// strip so a failure stays visible after the user switches tabs.
@immutable
class ActionLog {
  const ActionLog({required this.message, required this.isError});

  /// Human-readable summary, e.g. `print → ok` or `connect error → …`.
  final String message;

  /// Whether [message] describes a failure; drives the status strip colour.
  final bool isError;
}

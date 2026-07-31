import 'package:flutter/material.dart';

import '../../model/action_log.dart';

/// Persistent one-line strip showing the last action outcome.
///
/// Lives in the shell rather than a tab so a failure raised on the Scan tab is
/// still readable after switching to Print.
class StatusStrip extends StatelessWidget {
  const StatusStrip({required this.log, super.key});

  final ActionLog? log;

  @override
  Widget build(BuildContext context) {
    final ActionLog? entry = log;
    if (entry == null) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    final Color background = entry.isError
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.secondaryContainer;
    final Color foreground = entry.isError
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onSecondaryContainer;
    return Material(
      color: background,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: <Widget>[
            Icon(
              entry.isError ? Icons.error_outline : Icons.check_circle_outline,
              size: 18,
              color: foreground,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                entry.message,
                style: theme.textTheme.bodySmall?.copyWith(color: foreground),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

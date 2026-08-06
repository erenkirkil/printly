import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/action_log.dart';

/// Persistent one-line strip showing the last action outcome.
///
/// Lives in the shell rather than a tab so a failure raised on the Scan tab is
/// still readable after switching to Print. Tapping the strip opens the full
/// history: a field tester needs to read and copy a long typed-error message
/// (e.g. `PrintlyConnectionException(connect_timeout): …`) whose tail used to
/// be cut off by the strip's own `maxLines: 2` ellipsis, and needs the
/// preceding `connect attempt → …` line for context — the single-entry strip
/// discarded it the instant the error arrived.
class StatusStrip extends StatelessWidget {
  const StatusStrip({
    required this.log,
    required this.history,
    required this.onClear,
    super.key,
  });

  /// The most recent action outcome, shown on the one-line strip.
  final ActionLog? log;

  /// The full log history, newest first, shown when the strip is tapped.
  final List<ActionLog> history;

  /// Invoked when the tester chooses "Clear" in the history sheet.
  final VoidCallback onClear;

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
      child: InkWell(
        onTap: () => _showHistorySheet(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: <Widget>[
              Icon(
                entry.isError
                    ? Icons.error_outline
                    : Icons.check_circle_outline,
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
              const SizedBox(width: 8),
              Icon(Icons.unfold_more, size: 16, color: foreground),
            ],
          ),
        ),
      ),
    );
  }

  void _showHistorySheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) {
        return _ActionLogSheet(history: history, onClear: onClear);
      },
    );
  }
}

/// Formats an [ActionLog] timestamp as `HH:mm:ss` for the history sheet.
///
/// Hand-rolled instead of pulling in `intl`: the example deliberately keeps
/// zero extra dependencies, and zero-padding three integers doesn't need one.
String _formatTimestamp(DateTime at) {
  String pad(int value) => value.toString().padLeft(2, '0');
  return '${pad(at.hour)}:${pad(at.minute)}:${pad(at.second)}';
}

/// Renders a single history line as `HH:mm:ss  message`.
String _formatEntry(ActionLog entry) =>
    '${_formatTimestamp(entry.at)}  ${entry.message}';

/// Scrollable history sheet: every retained [ActionLog], newest first, each
/// selectable so the tester can copy a single line, plus a header with
/// "Copy all" and "Clear" actions.
class _ActionLogSheet extends StatelessWidget {
  const _ActionLogSheet({required this.history, required this.onClear});

  final List<ActionLog> history;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      builder: (BuildContext context, ScrollController controller) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'Action log',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    TextButton(
                      onPressed: history.isEmpty
                          ? null
                          : () => _copyAll(context),
                      child: const Text('Copy all'),
                    ),
                    TextButton(
                      onPressed: history.isEmpty ? null : onClear,
                      child: const Text('Clear'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: history.isEmpty
                    ? const Center(child: Text('No actions logged yet.'))
                    : ListView.builder(
                        controller: controller,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        itemCount: history.length,
                        itemBuilder: (BuildContext context, int index) {
                          final ActionLog entry = history[index];
                          final Color? color = entry.isError
                              ? theme.colorScheme.error
                              : null;
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: SelectableText(
                              _formatEntry(entry),
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                                color: color,
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _copyAll(BuildContext context) async {
    final String text = history.map(_formatEntry).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Log copied to clipboard')));
  }
}

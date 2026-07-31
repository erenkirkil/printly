import 'package:flutter/material.dart';

/// A labelled read-only value with an optional trailing icon.
class InfoCard extends StatelessWidget {
  const InfoCard({
    required this.label,
    required this.value,
    this.trailing,
    super.key,
  });

  final String label;
  final String value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(label, style: theme.textTheme.labelMedium),
                  const SizedBox(height: 4),
                  Text(value, style: theme.textTheme.titleMedium),
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

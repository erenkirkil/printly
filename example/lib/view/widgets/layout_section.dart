import 'package:flutter/material.dart';

import '../../viewmodel/print_view_model.dart';

/// The ASCII layout / ruler probe used to validate paper geometry.
class LayoutSection extends StatelessWidget {
  const LayoutSection({required this.vm, super.key});

  final PrintViewModel vm;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('Text layout', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: vm.canPrint ? vm.printLayoutSample : null,
          icon: const Icon(Icons.straighten),
          label: const Text('Print layout & ruler sample'),
        ),
      ],
    );
  }
}

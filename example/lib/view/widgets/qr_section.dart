import 'package:flutter/material.dart';
import 'package:printly/printly.dart';

import '../../viewmodel/print_view_model.dart';

/// QR controls: payload field, error level, print and density demo.
class QrSection extends StatelessWidget {
  const QrSection({required this.vm, required this.controller, super.key});

  final PrintViewModel vm;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool enabled = vm.canPrint;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('QR code', style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'QR content (Latin-1)',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(
              child: DropdownButton<PrintlyQrErrorLevel>(
                isExpanded: true,
                value: vm.qrErrorLevel,
                items: <DropdownMenuItem<PrintlyQrErrorLevel>>[
                  for (final PrintlyQrErrorLevel l
                      in PrintlyQrErrorLevel.values)
                    DropdownMenuItem<PrintlyQrErrorLevel>(
                      value: l,
                      child: Text('EC ${l.name}'),
                    ),
                ],
                onChanged: enabled
                    ? (PrintlyQrErrorLevel? v) {
                        if (v != null) vm.qrErrorLevel = v;
                      }
                    : null,
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: enabled ? () => vm.printQr(controller.text) : null,
              child: const Text('Print QR'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: enabled ? vm.printQrDensityDemo : null,
          icon: const Icon(Icons.grid_on),
          label: const Text('Print QR density demo'),
        ),
      ],
    );
  }
}

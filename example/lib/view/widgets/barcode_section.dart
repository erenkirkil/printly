import 'package:flutter/material.dart';
import 'package:printly/printly.dart';

import '../../viewmodel/print_view_model.dart';

/// Barcode controls: payload field, symbology, print and full gallery.
class BarcodeSection extends StatelessWidget {
  const BarcodeSection({required this.vm, required this.controller, super.key});

  final PrintViewModel vm;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool enabled = vm.canPrint;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('Barcode', style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Barcode payload',
            helperText: 'Long codes may overflow 58 mm at this bar width',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(
              child: DropdownButton<PrintlyBarcodeType>(
                isExpanded: true,
                value: vm.barcodeType,
                items: <DropdownMenuItem<PrintlyBarcodeType>>[
                  for (final PrintlyBarcodeType t in PrintlyBarcodeType.values)
                    DropdownMenuItem<PrintlyBarcodeType>(
                      value: t,
                      child: Text(t.name),
                    ),
                ],
                onChanged: enabled
                    ? (PrintlyBarcodeType? v) {
                        if (v != null) vm.barcodeType = v;
                      }
                    : null,
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: enabled
                  ? () => vm.printBarcode(controller.text)
                  : null,
              child: const Text('Print'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: enabled ? vm.printBarcodeGallery : null,
          icon: const Icon(Icons.view_list),
          label: const Text('Print all symbologies'),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import '../viewmodel/print_view_model.dart';
import '../viewmodel/raster_view_model.dart';
import 'widgets/barcode_section.dart';
import 'widgets/layout_section.dart';
import 'widgets/qr_section.dart';
import 'widgets/raster_section.dart';

/// Everything that puts ink on paper.
///
/// Stateful only to own the two text controllers: per the MVVM split, editing
/// state stays in the view and [PrintViewModel] takes plain values.
class PrintTab extends StatefulWidget {
  const PrintTab({required this.vm, required this.raster, super.key});

  final PrintViewModel vm;
  final RasterViewModel raster;

  @override
  State<PrintTab> createState() => _PrintTabState();
}

class _PrintTabState extends State<PrintTab> {
  final TextEditingController _qrController = TextEditingController(
    text: 'https://github.com/erenkirkil/printly',
  );
  final TextEditingController _barcodeController = TextEditingController(
    text: 'PRINTLY123',
  );

  @override
  void dispose() {
    _qrController.dispose();
    _barcodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.vm,
      builder: (BuildContext context, _) {
        final bool enabled = widget.vm.canPrint;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            if (!enabled)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'Connect a device on the Scan tab to enable printing.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            RasterSection(vm: widget.raster),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: enabled ? widget.vm.printTurkishReceipt : null,
              icon: const Icon(Icons.receipt_long),
              label: const Text('Print Turkish test receipt (code page)'),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: enabled ? widget.vm.printCharsetDiagnostic : null,
              icon: const Icon(Icons.troubleshoot),
              label: const Text('Print charset diagnostic'),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text('Print lab', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 12),
                    QrSection(vm: widget.vm, controller: _qrController),
                    const Divider(height: 24),
                    BarcodeSection(
                      vm: widget.vm,
                      controller: _barcodeController,
                    ),
                    const Divider(height: 24),
                    LayoutSection(vm: widget.vm),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

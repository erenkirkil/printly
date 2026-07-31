import 'package:flutter/material.dart';
import 'package:printly/printly.dart';

import '../../viewmodel/raster_view_model.dart';

/// The raster lab: type size, weight and alignment on the left, and a live
/// preview of the exact dots the printer would burn.
///
/// Everything here can be judged without paper. Only the Print button spends
/// any.
class RasterSection extends StatefulWidget {
  const RasterSection({required this.vm, super.key});

  final RasterViewModel vm;

  @override
  State<RasterSection> createState() => _RasterSectionState();
}

class _RasterSectionState extends State<RasterSection> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.vm.text,
  );
  final TextEditingController _urlController = TextEditingController(
    //text: 'https://dart.dev/assets/img/logo/dart-64.png',
    text:
        'https://instagram.fist1-2.fna.fbcdn.net/v/t51.2885-19/352935843_776776870579835_6064485847843258392_n.jpg?efg=eyJ2ZW5jb2RlX3RhZyI6InByb2ZpbGVfcGljLmRqYW5nby42ODkuYzIifQ&_nc_ht=instagram.fist1-2.fna.fbcdn.net&_nc_cat=111&_nc_oc=Q6cZ2gHTL7hJDQWZFLny-5eNipYuYlBgrEJ54JVf9qv5EHMNowZ9xa34Mcc0sq55tcJ5OLQ&_nc_ohc=g7Hk6PS9BPAQ7kNvwF_9yph&_nc_gid=nz3PY9kj-apB8lx2lqI3Ug&edm=APs17CUBAAAA&ccb=7-5&oh=00_AQGx0LatbpAheqPmgYaqkOJTo8LUsYpYKd6hPaCC08Qs_Q&oe=6A72843C&_nc_sid=10d13b',
  );
  final GlobalKey _boundaryKey = GlobalKey();

  @override
  void dispose() {
    _controller.dispose();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.vm,
      builder: (BuildContext context, _) {
        final RasterViewModel vm = widget.vm;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text('Raster (Turkish)', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  'Glyphs are drawn, not looked up in a code page — this is the '
                  'path that works on printers that ignore ESC t.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),

                TextField(
                  controller: _controller,
                  maxLines: 5,
                  minLines: 2,
                  decoration: InputDecoration(
                    labelText: 'Receipt text',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixIcon: IconButton(
                      tooltip: 'Restore the sample',
                      icon: const Icon(Icons.restart_alt),
                      onPressed: () {
                        vm.resetText();
                        _controller.text = vm.text;
                      },
                    ),
                  ),
                  onChanged: (String value) => vm.text = value,
                ),
                const SizedBox(height: 12),

                Row(
                  children: <Widget>[
                    Text('Size', style: theme.textTheme.labelLarge),
                    Expanded(
                      child: Slider(
                        value: vm.fontSize,
                        min: 12,
                        max: 48,
                        divisions: 18,
                        label: '${vm.fontSize.round()} dots',
                        onChanged: (double v) => vm.fontSize = v,
                      ),
                    ),
                    Text(
                      '${vm.fontSize.round()} dots · '
                      '${(vm.fontSize / 8).toStringAsFixed(1)} mm',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),

                Row(
                  children: <Widget>[
                    Text('Ink', style: theme.textTheme.labelLarge),
                    Expanded(
                      child: Slider(
                        value: vm.threshold.toDouble(),
                        min: 96,
                        max: 224,
                        divisions: 16,
                        label: '${vm.threshold}',
                        onChanged: (double v) => vm.threshold = v.round(),
                      ),
                    ),
                    Text(
                      'cutoff ${vm.threshold}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
                Text(
                  'Higher burns the antialiased edges of each glyph too, which '
                  'is what stops ordinary weights printing washed out.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),

                Row(
                  children: <Widget>[
                    Expanded(
                      child: SegmentedButton<PrintlyTextAlign>(
                        segments: const <ButtonSegment<PrintlyTextAlign>>[
                          ButtonSegment<PrintlyTextAlign>(
                            value: PrintlyTextAlign.left,
                            icon: Icon(Icons.format_align_left),
                          ),
                          ButtonSegment<PrintlyTextAlign>(
                            value: PrintlyTextAlign.center,
                            icon: Icon(Icons.format_align_center),
                          ),
                          ButtonSegment<PrintlyTextAlign>(
                            value: PrintlyTextAlign.right,
                            icon: Icon(Icons.format_align_right),
                          ),
                        ],
                        selected: <PrintlyTextAlign>{vm.align},
                        onSelectionChanged: (Set<PrintlyTextAlign> s) =>
                            vm.align = s.first,
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      label: const Text('Bold'),
                      selected: vm.bold,
                      onSelected: (bool v) => vm.bold = v,
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                const Divider(height: 24),
                Text('Image from a URL', style: theme.textTheme.labelLarge),
                const SizedBox(height: 4),
                Text(
                  'printly takes bytes, not URLs — downloading is the app\'s '
                  'job. Keeping HTTP out of the plugin also keeps an INTERNET '
                  'permission out of every app that depends on it.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _urlController,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Image URL',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: vm.rendering
                      ? null
                      : () => vm.loadImageFromUrl(_urlController.text),
                  icon: const Icon(Icons.cloud_download_outlined),
                  label: const Text('Fetch & preview'),
                ),
                const SizedBox(height: 12),

                _PreviewPane(vm: vm, boundaryKey: _boundaryKey),
                const SizedBox(height: 12),

                Row(
                  children: <Widget>[
                    Text('Feed', style: theme.textTheme.labelLarge),
                    Expanded(
                      child: Slider(
                        value: vm.feedLines.toDouble(),
                        min: 0,
                        max: 8,
                        divisions: 8,
                        label: '${vm.feedLines}',
                        onChanged: (double v) => vm.feedLines = v.round(),
                      ),
                    ),
                    Text(
                      '${vm.feedLines} lines',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: vm.cutAfterPrint,
                  onChanged: (bool v) => vm.cutAfterPrint = v,
                  title: const Text('Cut after print'),
                  subtitle: const Text(
                    'Leave off on a printer with no cutter — some answer the '
                    'cut command by feeding a stretch of blank paper instead.',
                  ),
                ),
                const SizedBox(height: 8),

                FilledButton.icon(
                  onPressed: vm.canPrint ? vm.printPreview : null,
                  icon: const Icon(Icons.print),
                  label: const Text('Print this raster'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: vm.canPrint
                      ? () => vm.printWidget(_boundaryKey)
                      : null,
                  icon: const Icon(Icons.widgets_outlined),
                  label: const Text('Print the widget capture instead'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Side-by-side: what the printer will burn, and the widget-capture source.
class _PreviewPane extends StatelessWidget {
  const _PreviewPane({required this.vm, required this.boundaryKey});

  final RasterViewModel vm;
  final GlobalKey boundaryKey;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PrintlyBitmap? bitmap = vm.bitmap;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text('Preview', style: theme.textTheme.labelLarge),
            const SizedBox(width: 8),
            if (vm.rendering)
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            const Spacer(),
            if (bitmap != null && !bitmap.isEmpty)
              Text(
                '${bitmap.width}×${bitmap.height} · '
                '${bitmap.heightMm.toStringAsFixed(1)} mm · '
                '${bitmap.byteLength} B · '
                '${(vm.inkCoverage * 100).toStringAsFixed(1)}% ink',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: vm.coverageIsHigh ? theme.colorScheme.error : null,
                  fontWeight: vm.coverageIsHigh ? FontWeight.bold : null,
                ),
              ),
          ],
        ),
        if (vm.coverageIsHigh) ...<Widget>[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.warning_amber_rounded,
                  size: 18,
                  color: theme.colorScheme.onErrorContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Heavy coverage. A large solid-black area can draw more '
                    'current than the printer can sustain, and it may cut out '
                    'mid-receipt with no error your app can catch. Receipt '
                    'text sits near 8%.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: theme.dividerColor),
            borderRadius: BorderRadius.circular(4),
          ),
          child: vm.preview == null
              ? const SizedBox(
                  height: 40,
                  child: Center(child: Text('Nothing to preview')),
                )
              // Rendered at its natural dot size where it fits, so what is on
              // screen is dot-for-dot what the head receives.
              : FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.topLeft,
                  child: RawImage(
                    image: vm.preview,
                    filterQuality: FilterQuality.none,
                  ),
                ),
        ),
        const SizedBox(height: 12),

        Text('Widget capture source', style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        Text(
          'Must stay mounted and painted — an Offstage or zero-opacity subtree '
          'is never painted and cannot be captured.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Center(
          // The boundary keeps its natural 384 logical pixels so a capture at
          // pixelRatio 1.0 lands exactly on the paper width; FittedBox scales
          // only the presentation, and transforms above a boundary do not
          // affect what toImage sees.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: RepaintBoundary(
              key: boundaryKey,
              child: const _SampleReceipt(),
            ),
          ),
        ),
      ],
    );
  }
}

/// A small receipt laid out as widgets, sized to 58 mm at 203 dpi.
class _SampleReceipt extends StatelessWidget {
  const _SampleReceipt();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 384,
      color: Colors.white,
      padding: const EdgeInsets.all(12),
      child: DefaultTextStyle(
        style: const TextStyle(color: Colors.black, fontSize: 20, height: 1.3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              'PRINTLY MAĞAZA',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.black,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            const Text('Çağrı Şişli · İstanbul', textAlign: TextAlign.center),
            const Divider(color: Colors.black, height: 16),
            for (final (String, String) row in const <(String, String)>[
              ('Türk Kahvesi x2', '90,00'),
              ('Su', '5,50'),
            ])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: <Widget>[
                    Expanded(child: Text(row.$1)),
                    Text(row.$2),
                  ],
                ),
              ),
            const Divider(color: Colors.black, height: 16),
            const Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'TOPLAM',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Text('95,50', style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

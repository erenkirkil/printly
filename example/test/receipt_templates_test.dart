import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';
import 'package:printly_example/model/receipt_templates.dart';

/// Naive substring search over the ESC/POS byte stream — the same helper shape
/// the SDK's own print tests use.
bool _contains(List<int> haystack, List<int> needle) =>
    _indexOf(haystack, needle) >= 0;

int _indexOf(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || needle.length > haystack.length) return -1;
  outer:
  for (int i = 0; i <= haystack.length - needle.length; i++) {
    for (int j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

int _count(List<int> haystack, List<int> needle) {
  int found = 0;
  int from = 0;
  while (from <= haystack.length - needle.length) {
    final int at = _indexOf(haystack.sublist(from), needle);
    if (at < 0) break;
    found++;
    from += at + needle.length;
  }
  return found;
}

/// Builds a template's job offline — no device, no platform channel.
///
/// Goes through the public [PrintJob.create]; `PrintJob.fromGenerator` is
/// `@visibleForTesting` inside the package and must not be reached for from a
/// separate package.
Future<Uint8List> render(ReceiptTemplate template) async {
  final PrintJob job = await PrintJob.create(config: template.config);
  template.build(job);
  return job.build();
}

void main() {
  // PrintJob.create loads the ESC/POS capability profile from an asset bundle,
  // which needs the binding even in a plain test().
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReceiptTemplates', () {
    test('turkish selects CP857 and cuts exactly once', () async {
      final ReceiptTemplate template = ReceiptTemplates.turkish(
        PrintlyPaperWidth.mm58,
      );
      expect(template.config.charset, PrintlyCharset.turkish);
      expect(template.config.cutAfterPrint, isTrue);

      final Uint8List bytes = await render(template);
      expect(
        _contains(bytes, <int>[0x1B, 0x74, 0x0D]),
        isTrue,
        reason: 'ESC t 13 selects CP857',
      );
      expect(_count(bytes, <int>[0x1D, 0x56]), 1, reason: 'GS V, one cut');
    });

    test('turkish carries the Turkish glyphs as CP857 bytes', () async {
      final Uint8List bytes = await render(
        ReceiptTemplates.turkish(PrintlyPaperWidth.mm58),
      );
      final List<int> magaza = TurkishCodePage.encode(
        'PRINTLY MAĞAZA',
        charset: PrintlyCharset.turkish,
      );
      expect(_contains(bytes, magaza), isTrue);
      expect(
        _contains(bytes, 'PRINTLY MAĞAZA'.codeUnits),
        isFalse,
        reason: 'raw UTF-16 code units must never reach the printer',
      );
    });

    test('charsetDiagnostic sweeps every page from 0 to 50', () async {
      final Uint8List bytes = await render(
        ReceiptTemplates.charsetDiagnostic(PrintlyPaperWidth.mm58),
      );
      for (int n = 0; n <= 50; n++) {
        expect(
          _contains(bytes, <int>[0x1B, 0x74, n, 0x1C, 0x2E]),
          isTrue,
          reason: 'page $n missing from the sweep',
        );
      }
    });

    test('layout ruler matches the paper width', () async {
      for (final PrintlyPaperWidth paper in PrintlyPaperWidth.values) {
        final Uint8List bytes = await render(ReceiptTemplates.layout(paper));
        final String ruler = List<String>.generate(
          paper.maxCharsPerLine,
          (int i) => '${(i + 1) % 10}',
        ).join();
        expect(
          _contains(bytes, ruler.codeUnits),
          isTrue,
          reason:
              '${paper.name} ruler should span ${paper.maxCharsPerLine} cols',
        );
      }
    });

    test('priceRow pads the value flush right', () {
      expect(ReceiptTemplates.priceRow('A', 'B', 8), 'A      B');
      expect(ReceiptTemplates.priceRow('A', 'B', 8).length, 8);
    });

    test('priceRow degrades to a single space when the row overflows', () {
      expect(
        ReceiptTemplates.priceRow('LONGLABEL', '12345', 8),
        'LONGLABEL 12345',
      );
    });

    test('barcode rejects an invalid payload at build time', () async {
      final ReceiptTemplate template = ReceiptTemplates.barcode(
        PrintlyPaperWidth.mm58,
        data: 'NOT-DIGITS',
        type: PrintlyBarcodeType.ean13,
      );
      await expectLater(render(template), throwsArgumentError);
    });

    test('qr embeds the payload length in the header line', () async {
      const String data = 'PRINTLY';
      final Uint8List bytes = await render(
        ReceiptTemplates.qr(
          PrintlyPaperWidth.mm58,
          data: data,
          errorLevel: PrintlyQrErrorLevel.high,
        ),
      );
      expect(
        _contains(bytes, '${data.length} chars · EC high'.codeUnits),
        isFalse,
      );
      expect(_contains(bytes, '7 chars'.codeUnits), isTrue);
    });
  });
}

import 'package:printly/printly.dart';

/// A ready-to-print receipt: the [PrintConfig] the job must be created with,
/// plus the body that fills it.
///
/// Split this way so templates stay pure — they never touch `Printly.instance`,
/// which means tests can build the job themselves and assert on the bytes
/// without a device or a mocked platform.
class ReceiptTemplate {
  const ReceiptTemplate({required this.config, required this.build});

  /// Config the job must be created with (paper width, charset, cut policy).
  final PrintConfig config;

  /// Fills an already-created job with this template's content.
  final void Function(PrintJob job) build;
}

/// The playground's receipt catalogue. Every entry is a pure function of its
/// arguments, so `example/test/receipt_templates_test.dart` can exercise the
/// full byte output offline.
abstract final class ReceiptTemplates {
  /// Turkish sample receipt — the package's headline feature. Uses the CP857
  /// code-page path, which printers like the PTP-II ignore; that is exactly the
  /// gap the raster pipeline closes.
  static ReceiptTemplate turkish(PrintlyPaperWidth paper) {
    return ReceiptTemplate(
      config: PrintConfig(
        paperWidth: paper,
        charset: PrintlyCharset.turkish,
        feedLines: 3,
        cutAfterPrint: true,
      ),
      build: (PrintJob job) {
        job
          ..text(
            'PRINTLY MAĞAZA',
            align: PrintlyTextAlign.center,
            style: PrintlyTextStyle.bold,
            size: PrintlyTextSize.doubleHeight,
          )
          ..text('Çağrı Şişli - İstanbul', align: PrintlyTextAlign.center)
          ..divider()
          ..text('Ürün: Türk Kahvesi')
          ..text('Adet: 2 x 45,00 = 90,00 TL')
          ..divider()
          ..text('Teşekkür ederiz!', align: PrintlyTextAlign.center)
          ..feed(1)
          ..qr('https://github.com/erenkirkil/printly')
          ..feed(1)
          ..barcode('590123412345', type: PrintlyBarcodeType.ean13);
      },
    );
  }

  /// Sweeps every `ESC t n` code page from 0 to 50 and, on each row, prints the
  /// Turkish sample `ğĞşŞıİ` in BOTH CP857 and Windows-1254 byte layouts under
  /// that page. Whichever side renders correctly identifies the printer's
  /// Turkish page and encoding in a single print.
  ///
  /// Each row is preceded by `FS .` (cancel-kanji) so high bytes are treated as
  /// single-byte glyphs — exactly what the real text path does.
  ///
  /// Read the row where one side shows `ğĞşŞıİ` correctly: the number is the
  /// `ESC t` page; the left group means CP857, the right group means W1254.
  static ReceiptTemplate charsetDiagnostic(PrintlyPaperWidth paper) {
    return ReceiptTemplate(
      config: PrintConfig(paperWidth: paper, feedLines: 4),
      build: (PrintJob job) {
        job
          ..text(
            'TR PAGE SWEEP 0-50',
            align: PrintlyTextAlign.center,
            style: PrintlyTextStyle.bold,
          )
          ..text('nNN [CP857] | [W1254]')
          ..divider();

        const String tr = 'ğĞşŞıİ';
        final List<int> cp857 = TurkishCodePage.encode(
          tr,
          charset: PrintlyCharset.turkish,
        );
        final List<int> wpc = TurkishCodePage.encode(
          tr,
          charset: PrintlyCharset.windows1254,
        );
        for (int n = 0; n <= 50; n++) {
          job.raw(<int>[
            0x1B, 0x74, n, // ESC t n (select code page)
            0x1C, 0x2E, // FS . (cancel kanji → single-byte glyphs)
            ...'n$n '.codeUnits,
            ...cp857,
            ...' | '.codeUnits,
            ...wpc,
            0x0A,
          ]);
        }
        job.raw(<int>[0x1B, 0x74, 0x00]); // restore the default page
      },
    );
  }

  /// Prints [data] as a QR at [errorLevel], with the byte count above the
  /// symbol. The module size is chosen automatically from the payload length +
  /// error level, so a longer string yields a denser QR.
  static ReceiptTemplate qr(
    PrintlyPaperWidth paper, {
    required String data,
    required PrintlyQrErrorLevel errorLevel,
  }) {
    return ReceiptTemplate(
      config: PrintConfig(paperWidth: paper, feedLines: 3, cutAfterPrint: true),
      build: (PrintJob job) {
        job
          ..text(
            'QR TEST',
            align: PrintlyTextAlign.center,
            style: PrintlyTextStyle.bold,
          )
          ..text(
            '${data.length} chars · EC ${errorLevel.name}',
            align: PrintlyTextAlign.center,
          )
          ..feed(1)
          ..qr(data, errorLevel: errorLevel)
          ..feed(1)
          ..text(
            data,
            align: PrintlyTextAlign.center,
            charset: PrintlyCharset.latin,
          );
      },
    );
  }

  /// Three QR codes of growing payload length on one strip, so the
  /// module-density scaling is visible side by side on the paper.
  static ReceiptTemplate qrDensityDemo(PrintlyPaperWidth paper) {
    const List<String> payloads = <String>[
      'PRINTLY',
      'https://github.com/erenkirkil/printly',
      'https://printly.example.com/receipt?id=1234567890&store=istanbul'
          '&items=coffee,water,cake&total=95.50&ts=2026-07-01T15:56:00'
          '&sig=abcdef0123456789abcdef0123456789',
    ];
    return ReceiptTemplate(
      config: PrintConfig(paperWidth: paper, feedLines: 3, cutAfterPrint: true),
      build: (PrintJob job) {
        job.text(
          'QR DENSITY DEMO',
          align: PrintlyTextAlign.center,
          style: PrintlyTextStyle.bold,
        );
        for (final String payload in payloads) {
          job
            ..divider()
            ..text('${payload.length} chars', align: PrintlyTextAlign.center)
            ..qr(payload)
            ..feed(1);
        }
      },
    );
  }

  /// Prints [data] with the selected symbology. Invalid payloads (e.g. letters
  /// in an EAN-13) throw [ArgumentError], surfaced in the status strip.
  static ReceiptTemplate barcode(
    PrintlyPaperWidth paper, {
    required String data,
    required PrintlyBarcodeType type,
  }) {
    return ReceiptTemplate(
      config: PrintConfig(paperWidth: paper, feedLines: 3, cutAfterPrint: true),
      build: (PrintJob job) {
        job
          ..text(
            'BARCODE TEST',
            align: PrintlyTextAlign.center,
            style: PrintlyTextStyle.bold,
          )
          ..text(
            '${type.name} · ${data.length} chars',
            align: PrintlyTextAlign.center,
          )
          ..feed(1)
          ..barcode(data, type: type, height: 80, width: 2)
          ..feed(1);
      },
    );
  }

  /// One valid sample per supported symbology, so the whole barcode catalogue
  /// can be eyeballed on a single strip.
  static ReceiptTemplate barcodeGallery(PrintlyPaperWidth paper) {
    const List<(PrintlyBarcodeType, String)> samples =
        <(PrintlyBarcodeType, String)>[
          (PrintlyBarcodeType.ean13, '590123412345'),
          (PrintlyBarcodeType.ean8, '1234567'),
          (PrintlyBarcodeType.upcA, '01234567890'),
          (PrintlyBarcodeType.code39, 'CODE-39'),
          (PrintlyBarcodeType.code128, 'PRINTLY'),
          (PrintlyBarcodeType.itf, '12345678'),
          (PrintlyBarcodeType.codabar, 'A12345B'),
        ];
    return ReceiptTemplate(
      config: PrintConfig(paperWidth: paper, feedLines: 3, cutAfterPrint: true),
      build: (PrintJob job) {
        job.text(
          'BARCODE GALLERY',
          align: PrintlyTextAlign.center,
          style: PrintlyTextStyle.bold,
        );
        for (final (PrintlyBarcodeType type, String data) in samples) {
          job
            ..divider()
            ..text('${type.name}: $data', align: PrintlyTextAlign.center)
            ..barcode(data, type: type, height: 70, width: 2)
            ..feed(1);
        }
      },
    );
  }

  /// An ASCII layout probe: every alignment, size and emphasis, a right-aligned
  /// numeric price column, and a per-column ruler — pure ASCII so it renders
  /// correctly even on a CP437-only printer and validates the paper geometry
  /// (columns per line, alignment, magnification).
  static ReceiptTemplate layout(PrintlyPaperWidth paper) {
    final int cpl = paper.maxCharsPerLine;
    final String ruler = List<String>.generate(
      cpl,
      (int i) => '${(i + 1) % 10}',
    ).join();
    return ReceiptTemplate(
      config: PrintConfig(
        paperWidth: paper,
        charset: PrintlyCharset.latin,
        feedLines: 3,
        cutAfterPrint: true,
      ),
      build: (PrintJob job) {
        job
          ..text(
            'LAYOUT & RULER',
            align: PrintlyTextAlign.center,
            style: PrintlyTextStyle.bold,
            size: PrintlyTextSize.doubleHeight,
          )
          ..text(
            '$cpl cols · ${paper.dots} dots',
            align: PrintlyTextAlign.center,
          )
          ..divider()
          ..text('Left', align: PrintlyTextAlign.left)
          ..text('Center', align: PrintlyTextAlign.center)
          ..text('Right', align: PrintlyTextAlign.right)
          ..divider()
          ..text('Normal 1x1')
          ..text('Double width', size: PrintlyTextSize.doubleWidth)
          ..text('Double height', size: PrintlyTextSize.doubleHeight)
          ..text('Double W+H', size: PrintlyTextSize.doubleWidthHeight)
          ..divider()
          ..text('Bold', style: PrintlyTextStyle.bold)
          ..text('Underline', style: PrintlyTextStyle.underline)
          ..text('Bold + Underline', style: PrintlyTextStyle.boldUnderline)
          ..divider()
          ..text(priceRow('Coffee x2', '90.00', cpl))
          ..text(priceRow('Water', '5.50', cpl))
          ..text(priceRow('TOTAL', '95.50', cpl), style: PrintlyTextStyle.bold)
          ..divider()
          ..text('Column ruler:')
          ..text(ruler);
      },
    );
  }

  /// Pads [left] and [right] to fill [width] columns with the value flush right
  /// — a receipt "label        value" row. Falls back to a single space when the
  /// two strings already exceed the line.
  static String priceRow(String left, String right, int width) {
    final int gap = width - left.length - right.length;
    if (gap < 1) return '$left $right';
    return '$left${' ' * gap}$right';
  }
}

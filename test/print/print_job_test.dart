import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';

/// Counts how many times [needle] appears as a contiguous run in [haystack].
int _count(List<int> haystack, List<int> needle) {
  int count = 0;
  for (int i = 0; i <= haystack.length - needle.length; i++) {
    bool match = true;
    for (int j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) count++;
  }
  return count;
}

/// True when [needle] appears as a contiguous run inside [haystack].
bool _contains(List<int> haystack, List<int> needle) =>
    _indexOf(haystack, needle) != -1;

/// Index of the first contiguous occurrence of [needle] in [haystack], or -1.
int _indexOf(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || needle.length > haystack.length) return -1;
  for (int i = 0; i <= haystack.length - needle.length; i++) {
    bool match = true;
    for (int j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  return -1;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CapabilityProfile profile;

  setUpAll(() async {
    profile = await CapabilityProfile.load();
  });

  PrintJob job({PrintConfig config = const PrintConfig()}) {
    final PaperSize paper = config.paperWidth == PrintlyPaperWidth.mm80
        ? PaperSize.mm80
        : PaperSize.mm58;
    return PrintJob.fromGenerator(
      generator: Generator(paper, profile),
      config: config,
    );
  }

  group('PrintJob.text', () {
    test('selects CP857 then emits the verified Turkish byte', () {
      final List<int> bytes = job()
          .text('ş', charset: PrintlyCharset.turkish)
          .build();
      // ESC t 13 (0x0D) selects CP857; ş encodes to the CP857 byte 0x9F.
      // (The library inserts position/kanji-off bytes between them, so the
      // selector and the glyph byte are asserted independently.)
      expect(_contains(bytes, <int>[0x1B, 0x74, 0x0D]), isTrue);
      expect(bytes.contains(0x9F), isTrue);
    });

    test('emits ESC t 0 for the latin default', () {
      final List<int> bytes = job().text('A').build();
      expect(_contains(bytes, <int>[0x1B, 0x74, 0x00]), isTrue);
    });

    test('emits bold (ESC E 1) for a bold style', () {
      final List<int> bytes = job()
          .text('X', style: PrintlyTextStyle.bold)
          .build();
      expect(_contains(bytes, <int>[0x1B, 0x45, 0x01]), isTrue);
    });

    test('emits centre alignment (ESC a 1)', () {
      final List<int> bytes = job()
          .text('X', align: PrintlyTextAlign.center)
          .build();
      expect(_contains(bytes, <int>[0x1B, 0x61, 0x31]), isTrue);
    });
  });

  group('PrintJob text size (GS !)', () {
    // The generator computes the operand as decSize = 16*(w-1) + (h-1).
    test('doubleWidthHeight emits GS ! 0x11', () {
      final List<int> bytes = job()
          .text('X', size: PrintlyTextSize.doubleWidthHeight)
          .build();
      expect(_contains(bytes, <int>[0x1D, 0x21, 0x11]), isTrue);
    });

    test('doubleWidth emits GS ! 0x10', () {
      final List<int> bytes = job()
          .text('X', size: PrintlyTextSize.doubleWidth)
          .build();
      expect(_contains(bytes, <int>[0x1D, 0x21, 0x10]), isTrue);
    });

    test('doubleHeight emits GS ! 0x01', () {
      final List<int> bytes = job()
          .text('X', size: PrintlyTextSize.doubleHeight)
          .build();
      expect(_contains(bytes, <int>[0x1D, 0x21, 0x01]), isTrue);
    });
  });

  group('PrintJob style reset between lines', () {
    test('a bold line followed by a normal line emits ESC E 0', () {
      final List<int> bytes =
          (job()
                ..text('a', style: PrintlyTextStyle.bold)
                ..text('b'))
              .build();
      final int boldOn = _indexOf(bytes, <int>[0x1B, 0x45, 0x01]);
      final int boldOff = _indexOf(bytes, <int>[0x1B, 0x45, 0x00]);
      expect(boldOn, isNot(-1));
      expect(boldOff, isNot(-1));
      expect(boldOff, greaterThan(boldOn));
    });

    test('a sized line followed by a normal line emits GS ! 0', () {
      final List<int> bytes =
          (job()
                ..text('a', size: PrintlyTextSize.doubleWidthHeight)
                ..text('b'))
              .build();
      final int sizeOn = _indexOf(bytes, <int>[0x1D, 0x21, 0x11]);
      final int sizeOff = _indexOf(bytes, <int>[0x1D, 0x21, 0x00]);
      expect(sizeOn, isNot(-1));
      expect(sizeOff, isNot(-1));
      expect(sizeOff, greaterThan(sizeOn));
    });
  });

  group('PrintJob.create', () {
    test(
      'a supplied config paperWidth wins over the paperWidth argument',
      () async {
        final PrintJob created = await PrintJob.create(
          paperWidth: PrintlyPaperWidth.mm80,
          config: const PrintConfig(),
        );
        // Documented precedence: config.paperWidth (mm58 default) wins.
        expect(created.paperWidth, PrintlyPaperWidth.mm58);
      },
    );

    test('a second create() succeeds via the cached profile', () async {
      final PrintJob first = await PrintJob.create();
      final PrintJob second = await PrintJob.create(
        paperWidth: PrintlyPaperWidth.mm80,
      );
      expect(first.paperWidth, PrintlyPaperWidth.mm58);
      expect(second.paperWidth, PrintlyPaperWidth.mm80);
      expect(second.text('A').build(), isNotEmpty);
    });
  });

  group('PrintJob structural commands', () {
    test('feed emits ESC d n', () {
      final List<int> bytes = job().feed(2).build();
      expect(_contains(bytes, <int>[0x1B, 0x64, 0x02]), isTrue);
    });

    test('cut emits GS V 0 for a full cut', () {
      final List<int> bytes = job().cut().build();
      expect(_contains(bytes, <int>[0x1D, 0x56, 0x30]), isTrue);
    });

    test('divider draws a full 58 mm line of dashes', () {
      final List<int> bytes = job().divider().build();
      expect(_contains(bytes, List<int>.filled(32, 0x2D)), isTrue);
    });

    test('divider widens to 48 dashes on 80 mm paper', () {
      final List<int> bytes = job(
        config: const PrintConfig(paperWidth: PrintlyPaperWidth.mm80),
      ).divider().build();
      expect(_contains(bytes, List<int>.filled(48, 0x2D)), isTrue);
    });

    test('raw bytes are appended verbatim', () {
      final List<int> bytes = job().raw(<int>[0x1B, 0x21, 0x10]).build();
      expect(_contains(bytes, <int>[0x1B, 0x21, 0x10]), isTrue);
    });
  });

  group('PrintJob.barcode', () {
    test('emits a GS k EAN13 barcode (function A, type 2)', () {
      final List<int> bytes = job()
          .barcode('590123412345', type: PrintlyBarcodeType.ean13)
          .build();
      expect(_contains(bytes, <int>[0x1D, 0x6B, 0x02]), isTrue);
    });

    test('auto-prefixes CODE128 with the {B code set', () {
      final List<int> bytes = job()
          .barcode('AB12', type: PrintlyBarcodeType.code128)
          .build();
      // GS k 73 (0x49) then length then '{' 'B' 'A' 'B' '1' '2'.
      expect(_contains(bytes, <int>[0x7B, 0x42, 0x41, 0x42]), isTrue);
    });

    test('throws ArgumentError on an invalid payload', () {
      expect(
        () => job().barcode('XYZ', type: PrintlyBarcodeType.ean13),
        throwsArgumentError,
      );
    });

    test('escapes literal { in auto-prefixed CODE128 payloads', () {
      final List<int> bytes = job()
          .barcode('A{B', type: PrintlyBarcodeType.code128)
          .build();
      // '{B' selector, then 'A', then the escaped literal '{{', then 'B'.
      expect(
        _contains(bytes, <int>[0x7B, 0x42, 0x41, 0x7B, 0x7B, 0x42]),
        isTrue,
      );
    });

    test('honours a caller-supplied {C selector and escapes the rest', () {
      final List<int> bytes = job()
          .barcode('{C12{3', type: PrintlyBarcodeType.code128)
          .build();
      // '{C' kept, '12' passed through, literal '{' doubled, '3' follows.
      expect(
        _contains(bytes, <int>[0x7B, 0x43, 0x31, 0x32, 0x7B, 0x7B, 0x33]),
        isTrue,
      );
    });

    test('emits the default module width (GS w 3) on every barcode', () {
      final List<int> bytes = job()
          .barcode('AB12', type: PrintlyBarcodeType.code128)
          .build();
      expect(_contains(bytes, <int>[0x1D, 0x77, 0x03]), isTrue);
    });

    test('clamps module width into the spec range 2..6', () {
      final List<int> wide = job()
          .barcode('AB12', type: PrintlyBarcodeType.code128, width: 99)
          .build();
      expect(_contains(wide, <int>[0x1D, 0x77, 0x06]), isTrue);

      final List<int> narrow = job()
          .barcode('AB12', type: PrintlyBarcodeType.code128, width: 0)
          .build();
      expect(_contains(narrow, <int>[0x1D, 0x77, 0x02]), isTrue);
    });
  });

  group('PrintJob.qr', () {
    test('emits a GS ( k QR header', () {
      final List<int> bytes = job().qr('https://example.com').build();
      expect(_contains(bytes, <int>[0x1D, 0x28, 0x6B]), isTrue);
    });

    test('short payload stores with single-byte length and pH 0', () {
      final List<int> bytes = job().qr('ABCD').build();
      // Function 180 store: len = 4 + 3 = 7 → pL 0x07, pH 0x00, then data.
      expect(
        // dart format off
        _contains(bytes, <int>[
          0x1D, 0x28, 0x6B, 0x07, 0x00, 0x31, 0x50, 0x30,
          0x41, 0x42, 0x43, 0x44,
        ]),
        // dart format on
        isTrue,
      );
    });

    test('300-byte payload stores with correct pL/pH (regression)', () {
      // 300 + 3 = 303 = 0x012F → pL 0x2F, pH 0x01. The wrapped library
      // hardcoded pH 0 and overflowed pL, corrupting payloads > 252 bytes.
      final List<int> bytes = job().qr('A' * 300).build();
      expect(
        _contains(bytes, <int>[0x1D, 0x28, 0x6B, 0x2F, 0x01, 0x31, 0x50, 0x30]),
        isTrue,
      );
      // And the print function is still emitted after the payload.
      expect(
        _contains(bytes, <int>[0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x51, 0x30]),
        isTrue,
      );
    });

    test('emits the requested error-correction level (function 169)', () {
      final List<int> bytes = job()
          .qr('HELLO', errorLevel: PrintlyQrErrorLevel.high)
          .build();
      // H → 51 per the ESC/POS spec.
      expect(
        _contains(bytes, <int>[0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x45, 51]),
        isTrue,
      );
    });

    test('rejects payloads beyond the QR byte-mode maximum', () {
      expect(() => job().qr('A' * 2954), throwsArgumentError);
    });

    test(
      'throws ArgumentError for non-Latin-1 (e.g. Turkish ş/ı) payloads',
      () {
        expect(() => job().qr('ışık'), throwsArgumentError);
      },
    );

    test('accepts Latin-1 representable accents', () {
      // ü/ç/ö are within Latin-1, so this must not throw.
      expect(() => job().qr('https://x.com/cafe-uc'), returnsNormally);
    });
  });

  group('PrintJob regression fixes', () {
    test('barcode height is clamped to 255 (GS h)', () {
      final List<int> bytes = job()
          .barcode('AB12', type: PrintlyBarcodeType.code128, height: 300)
          .build();
      expect(_contains(bytes, <int>[0x1D, 0x68, 0xFF]), isTrue);
    });

    test('divider with an astral char prints a predictable row of "?"', () {
      final List<int> bytes = job().divider(char: '😀').build();
      expect(_contains(bytes, List<int>.filled(32, 0x3F)), isTrue);
    });

    test('build does not double-cut when cut() was already chained', () {
      final List<int> bytes =
          (job(config: const PrintConfig(cutAfterPrint: true))
                ..text('A')
                ..cut())
              .build();
      expect(_count(bytes, <int>[0x1D, 0x56, 0x30]), 1);
    });
  });

  group('PrintJob.build finalisers', () {
    test('applies config feedLines and cut', () {
      final List<int> bytes = job(
        config: const PrintConfig(feedLines: 3, cutAfterPrint: true),
      ).text('A').build();
      expect(_contains(bytes, <int>[0x1B, 0x64, 0x03]), isTrue);
      expect(_contains(bytes, <int>[0x1D, 0x56, 0x30]), isTrue);
    });

    test('is idempotent across repeated calls', () {
      final PrintJob j = job()
        ..text('A')
        ..feed(1);
      expect(j.build(), j.build());
    });
  });
}

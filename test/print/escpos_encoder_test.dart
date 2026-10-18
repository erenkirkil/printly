import 'dart:convert' show latin1;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';
import 'package:printly/src/print/escpos_encoder.dart';
import 'package:printly/src/raster/raster_encoder.dart';

import 'escpos_frozen_golden_test.dart';

void main() {
  group('EscPosEncoder unit commands (Epson ESC/POS spec)', () {
    test('reset emits ESC @ (0x1B 0x40)', () {
      final EscPosEncoder encoder = EscPosEncoder();
      expect(encoder.reset(), const <int>[0x1B, 0x40]);
    });

    test('feed emits ESC d n for valid range 1..255', () {
      final EscPosEncoder encoder = EscPosEncoder();
      expect(encoder.feed(1), const <int>[0x1B, 0x64, 0x01]);
      expect(encoder.feed(255), const <int>[0x1B, 0x64, 0xFF]);
    });

    test('feed rejects out-of-range counts in debug mode', () {
      final EscPosEncoder encoder = EscPosEncoder();
      expect(() => encoder.feed(0), throwsAssertionError);
      expect(() => encoder.feed(-1), throwsAssertionError);
      expect(() => encoder.feed(256), throwsAssertionError);
    });

    test('cut emits 5 LFs + GS V 0 (full) or GS V 1 (partial)', () {
      final EscPosEncoder encoder = EscPosEncoder();
      expect(encoder.cut(), const <int>[
        0x0A,
        0x0A,
        0x0A,
        0x0A,
        0x0A,
        0x1D,
        0x56,
        0x30,
      ]);
      expect(encoder.cut(mode: PrintlyCutMode.partial), const <int>[
        0x0A,
        0x0A,
        0x0A,
        0x0A,
        0x0A,
        0x1D,
        0x56,
        0x31,
      ]);
    });

    test('text frames payload with ESC \$ 0 0, setStyles, and trailing LF', () {
      final EscPosEncoder encoder = EscPosEncoder();
      final List<int> out = encoder.text(Uint8List.fromList(<int>[0x41, 0x42]));
      expect(out, const <int>[
        0x1B, 0x24, 0x00, 0x00, // ESC $ 0 0
        0x1C, 0x2E, // FS . (no style diff on default left/normal/1x1)
        0x41, 0x42, // "AB"
        0x0A, // LF
      ]);
    });
  });

  group('EscPosEncoder style cache invariants', () {
    test('initial left/normal/1x1 state emits zero style diff bytes', () {
      final EscPosEncoder encoder = EscPosEncoder();
      expect(encoder.setStyles(), const <int>[0x1C, 0x2E]);
    });

    test('emits styles in fixed order: align → bold → underline → size', () {
      final EscPosEncoder encoder = EscPosEncoder();
      expect(
        encoder.setStyles(
          align: PrintlyTextAlign.right,
          style: PrintlyTextStyle.boldUnderline,
          size: PrintlyTextSize.doubleWidthHeight,
        ),
        const <int>[
          0x1B, 0x61, 0x32, // ESC a '2' (right)
          0x1B, 0x45, 0x01, // ESC E 1 (bold on)
          0x1B, 0x2D, 0x01, // ESC - 1 (underline on)
          0x1D, 0x21, 0x11, // GS ! 0x11 (2x width, 2x height)
          0x1C, 0x2E, // FS .
        ],
      );
    });

    test('repeating identical styles emits zero diff bytes', () {
      final EscPosEncoder encoder = EscPosEncoder();
      encoder.setStyles(
        align: PrintlyTextAlign.center,
        style: PrintlyTextStyle.bold,
        size: PrintlyTextSize.doubleWidth,
      );
      expect(
        encoder.setStyles(
          align: PrintlyTextAlign.center,
          style: PrintlyTextStyle.bold,
          size: PrintlyTextSize.doubleWidth,
        ),
        const <int>[0x1C, 0x2E],
      );
    });

    test('reset() clears cached styles so subsequent styles re-emit', () {
      final EscPosEncoder encoder = EscPosEncoder();
      encoder.setStyles(
        align: PrintlyTextAlign.center,
        style: PrintlyTextStyle.bold,
      );
      expect(encoder.reset(), const <int>[0x1B, 0x40]);
      // After reset, center + bold must be emitted again.
      expect(
        encoder.setStyles(
          align: PrintlyTextAlign.center,
          style: PrintlyTextStyle.bold,
        ),
        const <int>[0x1B, 0x61, 0x31, 0x1B, 0x45, 0x01, 0x1C, 0x2E],
      );
    });

    test('setStyles(align:) resets active bold, underline, and size', () {
      final EscPosEncoder encoder = EscPosEncoder();
      encoder.setStyles(
        align: PrintlyTextAlign.left,
        style: PrintlyTextStyle.boldUnderline,
        size: PrintlyTextSize.doubleHeight,
      );
      expect(encoder.setStyles(align: PrintlyTextAlign.center), const <int>[
        0x1B, 0x61, 0x31, // center
        0x1B, 0x45, 0x00, // bold off
        0x1B, 0x2D, 0x00, // underline off
        0x1D, 0x21, 0x00, // size 1x1
        0x1C, 0x2E,
      ]);
    });
  });

  group('EscPosEncoder barcode validation', () {
    final EscPosEncoder encoder = EscPosEncoder();

    List<int> emit(PrintlyBarcodeType type, String data) => encoder.barcode(
      data,
      type: type,
      height: 60,
      width: 3,
      hriPosition: PrintlyHriPosition.below,
      align: PrintlyTextAlign.center,
    );

    test('validates UPC-A length (11 or 12) and digits', () {
      expect(
        () => emit(PrintlyBarcodeType.upcA, '01234567890'),
        returnsNormally,
      );
      expect(
        () => emit(PrintlyBarcodeType.upcA, '012345678905'),
        returnsNormally,
      );
      expect(
        () => emit(PrintlyBarcodeType.upcA, '0123456789'),
        throwsArgumentError,
      );
      expect(
        () => emit(PrintlyBarcodeType.upcA, '0123456789012'),
        throwsArgumentError,
      );
      expect(
        () => emit(PrintlyBarcodeType.upcA, '0123456789A'),
        throwsArgumentError,
      );
    });

    test('validates EAN-13 length (12 or 13) and digits', () {
      expect(
        () => emit(PrintlyBarcodeType.ean13, '590123412345'),
        returnsNormally,
      );
      expect(
        () => emit(PrintlyBarcodeType.ean13, '5901234123457'),
        returnsNormally,
      );
      expect(
        () => emit(PrintlyBarcodeType.ean13, '59012341234'),
        throwsArgumentError,
      );
      expect(
        () => emit(PrintlyBarcodeType.ean13, '59012341234X'),
        throwsArgumentError,
      );
    });

    test('validates EAN-8 length (7 or 8) and digits', () {
      expect(() => emit(PrintlyBarcodeType.ean8, '1234567'), returnsNormally);
      expect(() => emit(PrintlyBarcodeType.ean8, '12345670'), returnsNormally);
      expect(
        () => emit(PrintlyBarcodeType.ean8, '123456'),
        throwsArgumentError,
      );
      expect(
        () => emit(PrintlyBarcodeType.ean8, '123456A'),
        throwsArgumentError,
      );
    });

    test('validates CODE39 non-empty and allowed symbol set', () {
      expect(
        () => emit(PrintlyBarcodeType.code39, 'AZ09 \$%*+-./'),
        returnsNormally,
      );
      expect(() => emit(PrintlyBarcodeType.code39, ''), throwsArgumentError);
      expect(() => emit(PrintlyBarcodeType.code39, 'abc'), throwsArgumentError);
    });

    test('validates ITF even length >= 2 and digits', () {
      expect(() => emit(PrintlyBarcodeType.itf, '12'), returnsNormally);
      expect(() => emit(PrintlyBarcodeType.itf, '123456'), returnsNormally);
      expect(() => emit(PrintlyBarcodeType.itf, ''), throwsArgumentError);
      expect(() => emit(PrintlyBarcodeType.itf, '123'), throwsArgumentError);
      expect(() => emit(PrintlyBarcodeType.itf, '12A4'), throwsArgumentError);
    });

    test('validates CODABAR charset and start/stop case matching', () {
      expect(
        () => emit(PrintlyBarcodeType.codabar, 'A12345B'),
        returnsNormally,
      );
      expect(
        () => emit(PrintlyBarcodeType.codabar, 'a12-34:d'),
        returnsNormally,
      );
      expect(() => emit(PrintlyBarcodeType.codabar, 'A'), throwsArgumentError);
      expect(
        () => emit(PrintlyBarcodeType.codabar, 'A12345b'),
        throwsArgumentError,
      );
      expect(
        () => emit(PrintlyBarcodeType.codabar, 'a12345B'),
        throwsArgumentError,
      );
      expect(
        () => emit(PrintlyBarcodeType.codabar, 'A123455'),
        throwsArgumentError,
      );
      expect(
        () => emit(PrintlyBarcodeType.codabar, 'A12_45B'),
        throwsArgumentError,
      );
    });

    test('validates CODE128 length 2..255 and ASCII bytes', () {
      expect(() => emit(PrintlyBarcodeType.code128, '{BA'), returnsNormally);
      expect(() => emit(PrintlyBarcodeType.code128, 'A'), throwsArgumentError);
      expect(
        () => emit(PrintlyBarcodeType.code128, 'A' * 256),
        throwsArgumentError,
      );
      expect(
        () => emit(PrintlyBarcodeType.code128, '{B\u0080'),
        throwsArgumentError,
      );
    });
  });

  group(
    'Shadow golden suite — EscPosEncoder reproduces all 7 frozen goldens',
    () {
      List<int> emitText(
        EscPosEncoder encoder,
        String content, {
        PrintlyTextAlign align = PrintlyTextAlign.left,
        PrintlyTextStyle style = PrintlyTextStyle.normal,
        PrintlyTextSize size = PrintlyTextSize.normal,
        PrintlyCharset charset = PrintlyCharset.latin,
      }) {
        final int? escT = charset.escTCode;
        return <int>[
          if (escT != null) ...<int>[0x1B, 0x74, escT],
          ...encoder.text(
            TurkishCodePage.encode(content, charset: charset),
            align: align,
            style: style,
            size: size,
          ),
        ];
      }

      List<int> emitQr(
        EscPosEncoder encoder,
        String data, {
        int? maxModuleSize,
        PrintlyQrErrorLevel errorLevel = PrintlyQrErrorLevel.medium,
        PrintlyTextAlign align = PrintlyTextAlign.center,
        PrintlyPaperWidth paperWidth = PrintlyPaperWidth.mm58,
      }) {
        final Uint8List payload = Uint8List.fromList(latin1.encode(data));
        final int moduleSize = QrSizing.moduleSize(
          data: data,
          errorLevel: errorLevel,
          paperDots: paperWidth.dots,
          maxModuleSize: maxModuleSize,
        );
        final int storeLen = payload.length + 3;
        final int levelByte = switch (errorLevel) {
          PrintlyQrErrorLevel.low => 48,
          PrintlyQrErrorLevel.medium => 49,
          PrintlyQrErrorLevel.quartile => 50,
          PrintlyQrErrorLevel.high => 51,
        };
        return <int>[
          ...encoder.setStyles(align: align),
          0x1D,
          0x28,
          0x6B,
          0x03,
          0x00,
          0x31,
          0x43,
          moduleSize,
          0x1D,
          0x28,
          0x6B,
          0x03,
          0x00,
          0x31,
          0x45,
          levelByte,
          0x1D,
          0x28,
          0x6B,
          storeLen & 0xFF,
          (storeLen >> 8) & 0xFF,
          0x31,
          0x50,
          0x30,
          ...payload,
          0x1D,
          0x28,
          0x6B,
          0x03,
          0x00,
          0x31,
          0x51,
          0x30,
        ];
      }

      test('1. representative receipt shadow matches frozen golden', () {
        final EscPosEncoder encoder = EscPosEncoder();
        final List<int> bytes = <int>[
          ...encoder.reset(),
          ...emitText(
            encoder,
            'MAĞAZA',
            align: PrintlyTextAlign.center,
            style: PrintlyTextStyle.bold,
            charset: PrintlyCharset.turkish,
          ),
          ...emitText(encoder, '-' * 32, charset: PrintlyCharset.latin),
          ...emitText(encoder, 'Teşekkürler', charset: PrintlyCharset.turkish),
          ...encoder.barcode(
            '{BAB12',
            type: PrintlyBarcodeType.code128,
            height: 60,
            width: 3,
            hriPosition: PrintlyHriPosition.below,
            align: PrintlyTextAlign.center,
          ),
          ...emitQr(encoder, 'https://example.com'),
          ...encoder.feed(2),
          ...encoder.cut(),
        ];
        expect(bytes, kFrozenRepresentativeReceiptBytes);
      });

      test('2. align × style × size matrix shadow matches frozen golden', () {
        final EscPosEncoder encoder = EscPosEncoder();
        final List<int> bytes = <int>[
          ...encoder.reset(),
          ...emitText(encoder, 'L0'),
          ...emitText(
            encoder,
            'C-B-DW',
            align: PrintlyTextAlign.center,
            style: PrintlyTextStyle.bold,
            size: PrintlyTextSize.doubleWidth,
          ),
          ...emitText(
            encoder,
            'R-U-DH',
            align: PrintlyTextAlign.right,
            style: PrintlyTextStyle.underline,
            size: PrintlyTextSize.doubleHeight,
          ),
          ...emitText(
            encoder,
            'L-BU-DWH',
            align: PrintlyTextAlign.left,
            style: PrintlyTextStyle.boldUnderline,
            size: PrintlyTextSize.doubleWidthHeight,
          ),
          ...emitText(encoder, 'N'),
        ];
        expect(bytes, kFrozenAlignStyleSizeMatrixBytes);
      });

      test(
        '3. consecutive identical-style lines shadow matches frozen golden',
        () {
          final EscPosEncoder encoder = EscPosEncoder();
          final List<int> bytes = <int>[
            ...encoder.reset(),
            ...emitText(
              encoder,
              'S1',
              align: PrintlyTextAlign.center,
              style: PrintlyTextStyle.boldUnderline,
              size: PrintlyTextSize.doubleWidth,
            ),
            ...emitText(
              encoder,
              'S2',
              align: PrintlyTextAlign.center,
              style: PrintlyTextStyle.boldUnderline,
              size: PrintlyTextSize.doubleWidth,
            ),
            ...emitText(
              encoder,
              '',
              align: PrintlyTextAlign.center,
              style: PrintlyTextStyle.boldUnderline,
              size: PrintlyTextSize.doubleWidth,
            ),
          ];
          expect(bytes, kFrozenStyleCacheZeroDiffBytes);
        },
      );

      test(
        '4. style cache coherence across barcode/QR/bitmap shadow matches',
        () {
          final EscPosEncoder encoder = EscPosEncoder();
          final List<int> bytes = <int>[
            ...encoder.reset(),
            ...emitText(
              encoder,
              'A',
              align: PrintlyTextAlign.right,
              style: PrintlyTextStyle.boldUnderline,
              size: PrintlyTextSize.doubleWidthHeight,
            ),
            ...encoder.barcode(
              '12345678',
              type: PrintlyBarcodeType.itf,
              height: 60,
              width: 3,
              hriPosition: PrintlyHriPosition.below,
              align: PrintlyTextAlign.center,
            ),
            ...emitText(
              encoder,
              'B',
              align: PrintlyTextAlign.center,
              style: PrintlyTextStyle.bold,
            ),
            ...emitQr(encoder, 'OK', align: PrintlyTextAlign.left),
            ...encoder.setStyles(align: PrintlyTextAlign.right),
            ...RasterEncoder.emit(buildSolidBlack8x2Bitmap(), bandHeight: 64),
            ...emitText(encoder, 'C'),
          ];
          expect(bytes, kFrozenStyleResetAcrossBarcodeQrBitmapBytes);
        },
      );

      test('5. all seven barcode symbologies shadow matches frozen golden', () {
        final EscPosEncoder encoder = EscPosEncoder();
        final List<int> bytes = <int>[
          ...encoder.reset(),
          ...encoder.barcode(
            '590123412345',
            type: PrintlyBarcodeType.ean13,
            height: 80,
            width: 2,
            hriPosition: PrintlyHriPosition.below,
            align: PrintlyTextAlign.center,
          ),
          ...encoder.barcode(
            '1234567',
            type: PrintlyBarcodeType.ean8,
            height: 50,
            width: 3,
            hriPosition: PrintlyHriPosition.above,
            align: PrintlyTextAlign.left,
          ),
          ...encoder.barcode(
            '01234567890',
            type: PrintlyBarcodeType.upcA,
            height: 60,
            width: 4,
            hriPosition: PrintlyHriPosition.both,
            align: PrintlyTextAlign.right,
          ),
          ...encoder.barcode(
            'CODE-39',
            type: PrintlyBarcodeType.code39,
            height: 60,
            width: 3,
            hriPosition: PrintlyHriPosition.none,
            align: PrintlyTextAlign.center,
          ),
          ...encoder.barcode(
            '123456',
            type: PrintlyBarcodeType.itf,
            height: 40,
            width: 5,
            hriPosition: PrintlyHriPosition.none,
            align: PrintlyTextAlign.center,
          ),
          ...encoder.barcode(
            'A12345B',
            type: PrintlyBarcodeType.codabar,
            height: 70,
            width: 6,
            hriPosition: PrintlyHriPosition.below,
            align: PrintlyTextAlign.center,
          ),
          ...encoder.barcode(
            '{BPRINT-128',
            type: PrintlyBarcodeType.code128,
            height: 60,
            width: 3,
            hriPosition: PrintlyHriPosition.below,
            align: PrintlyTextAlign.center,
          ),
        ];
        expect(bytes, kFrozenAllSevenBarcodesBytes);
      });

      test('6. short and 300-byte QR codes shadow matches frozen golden', () {
        final EscPosEncoder encoder = EscPosEncoder();
        final List<int> bytes = <int>[
          ...encoder.reset(),
          ...emitQr(
            encoder,
            'ABCD',
            errorLevel: PrintlyQrErrorLevel.low,
            maxModuleSize: 6,
            align: PrintlyTextAlign.left,
          ),
          ...emitQr(
            encoder,
            'Q-LVL',
            errorLevel: PrintlyQrErrorLevel.quartile,
            align: PrintlyTextAlign.right,
          ),
          ...emitQr(
            encoder,
            'A' * 300,
            errorLevel: PrintlyQrErrorLevel.high,
            align: PrintlyTextAlign.center,
          ),
        ];
        expect(bytes, kFrozenQrShortAndLongBytes);
      });

      test(
        '7. structural commands, charsets and finalisers shadow matches',
        () {
          final EscPosEncoder encoder = EscPosEncoder();
          final List<int> bytes = <int>[
            ...encoder.reset(),
            ...emitText(encoder, 'Şğü', charset: PrintlyCharset.turkish),
            ...emitText(encoder, 'Şğ', charset: PrintlyCharset.windows1254),
            ...emitText(encoder, 'Şğ', charset: PrintlyCharset.iso8859_9),
            ...emitText(encoder, 'Şğ', charset: PrintlyCharset.utf8),
            0x1B,
            0x33,
            0x10,
            ...encoder.feed(4),
            ...encoder.feed(3),
            ...encoder.cut(mode: PrintlyCutMode.partial),
          ];
          expect(bytes, kFrozenStructuralAndCharsetsBytes);
        },
      );
    },
  );
}

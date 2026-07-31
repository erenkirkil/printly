import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';

import 'raster_dither_test.dart' show kOpaqueBlack, kOpaqueWhite, rgba;

void main() {
  group('alignWidth', () {
    test('rounds down to a multiple of 8', () {
      expect(PrintlyBitmap.alignWidth(8), 8);
      expect(PrintlyBitmap.alignWidth(15), 8);
      expect(PrintlyBitmap.alignWidth(16), 16);
      expect(PrintlyBitmap.alignWidth(385), 384);
    });

    test('leaves both supported paper widths intact', () {
      for (final PrintlyPaperWidth paper in PrintlyPaperWidth.values) {
        expect(PrintlyBitmap.alignWidth(paper.dots), paper.dots);
      }
    });

    test('rejects anything narrower than one byte', () {
      expect(() => PrintlyBitmap.alignWidth(7), throwsArgumentError);
      expect(() => PrintlyBitmap.alignWidth(0), throwsArgumentError);
    });
  });

  group('blank', () {
    test('is all white and correctly sized', () {
      final PrintlyBitmap bitmap = PrintlyBitmap.blank(width: 384, height: 10);
      expect(bitmap.width, 384);
      expect(bitmap.widthBytes, 48);
      expect(bitmap.height, 10);
      expect(bitmap.byteLength, 480);
      expect(bitmap.bits.every((int b) => b == 0), isTrue);
      expect(bitmap.isEmpty, isFalse);
    });

    test('zero height is empty', () {
      final PrintlyBitmap bitmap = PrintlyBitmap.blank(width: 384, height: 0);
      expect(bitmap.isEmpty, isTrue);
      expect(bitmap.byteLength, 0);
    });
  });

  group('fromPremultipliedRgba', () {
    test('packs a black/white split MSB-first', () {
      final PrintlyBitmap bitmap = PrintlyBitmap.fromPremultipliedRgba(
        rgba: rgba(8, 1, (int x, int _) => x < 4 ? kOpaqueBlack : kOpaqueWhite),
        sourceWidth: 8,
        sourceHeight: 1,
        width: 8,
        dithering: PrintlyDithering.threshold,
      );
      expect(bitmap.bits, <int>[0xF0]);
    });

    test('aligns the requested width down and reports it', () {
      final PrintlyBitmap bitmap = PrintlyBitmap.fromPremultipliedRgba(
        rgba: rgba(20, 2, (_, _) => kOpaqueBlack),
        sourceWidth: 20,
        sourceHeight: 2,
        width: 20,
        dithering: PrintlyDithering.threshold,
      );
      expect(bitmap.width, 16);
      expect(bitmap.widthBytes, 2);
      expect(bitmap.byteLength, 4);
    });

    test('height passes through unchanged', () {
      final PrintlyBitmap bitmap = PrintlyBitmap.fromPremultipliedRgba(
        rgba: rgba(8, 37, (_, _) => kOpaqueWhite),
        sourceWidth: 8,
        sourceHeight: 37,
        width: 8,
      );
      expect(bitmap.height, 37);
      expect(bitmap.heightMm, closeTo(4.625, 0.001));
    });

    test('rejects an out-of-range threshold', () {
      expect(
        () => PrintlyBitmap.fromPremultipliedRgba(
          rgba: rgba(8, 1, (_, _) => kOpaqueBlack),
          sourceWidth: 8,
          sourceHeight: 1,
          width: 8,
          threshold: 256,
        ),
        throwsArgumentError,
      );
    });

    test('rejects an empty source', () {
      expect(
        () => PrintlyBitmap.fromPremultipliedRgba(
          rgba: Uint8List(0),
          sourceWidth: 0,
          sourceHeight: 0,
          width: 8,
        ),
        throwsArgumentError,
      );
    });
  });

  group('toRgba', () {
    test('round-trips a packed bitmap back to pixels', () {
      final PrintlyBitmap bitmap = PrintlyBitmap.fromPremultipliedRgba(
        rgba: rgba(8, 1, (int x, int _) => x < 4 ? kOpaqueBlack : kOpaqueWhite),
        sourceWidth: 8,
        sourceHeight: 1,
        width: 8,
        dithering: PrintlyDithering.threshold,
      );
      final Uint8List out = bitmap.toRgba();
      expect(out.length, 8 * 4);
      // First four pixels black, last four white, all opaque.
      for (int x = 0; x < 8; x++) {
        final int expected = x < 4 ? 0 : 255;
        expect(out[x * 4], expected, reason: 'pixel $x red');
        expect(out[x * 4 + 1], expected, reason: 'pixel $x green');
        expect(out[x * 4 + 2], expected, reason: 'pixel $x blue');
        expect(out[x * 4 + 3], 255, reason: 'pixel $x alpha');
      }
    });

    test('a blank bitmap expands to all white', () {
      final Uint8List out = PrintlyBitmap.blank(width: 16, height: 2).toRgba();
      expect(out.length, 16 * 2 * 4);
      expect(out.every((int b) => b == 255), isTrue);
    });

    test('survives a re-pack unchanged', () {
      // Pixels → dots → pixels → dots must be stable, otherwise a preview and
      // the printed output could disagree.
      final PrintlyBitmap first = PrintlyBitmap.fromPremultipliedRgba(
        rgba: rgba(
          16,
          4,
          (int x, int y) => (x + y).isEven ? kOpaqueBlack : kOpaqueWhite,
        ),
        sourceWidth: 16,
        sourceHeight: 4,
        width: 16,
        dithering: PrintlyDithering.threshold,
      );
      final PrintlyBitmap second = PrintlyBitmap.fromPremultipliedRgba(
        rgba: first.toRgba(),
        sourceWidth: 16,
        sourceHeight: 4,
        width: 16,
        dithering: PrintlyDithering.threshold,
      );
      expect(second.bits, first.bits);
    });
  });

  test('toString reports the geometry', () {
    expect(
      PrintlyBitmap.blank(width: 384, height: 2).toString(),
      'PrintlyBitmap(384 x 2 dots, 96 bytes)',
    );
  });
}

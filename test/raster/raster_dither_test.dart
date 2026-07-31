import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';
import 'package:printly/src/raster/raster_dither.dart';

/// Builds a premultiplied RGBA buffer from a per-pixel colour function.
Uint8List rgba(int width, int height, List<int> Function(int x, int y) pixel) {
  final Uint8List out = Uint8List(width * height * 4);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final List<int> c = pixel(x, y);
      final int i = (y * width + x) * 4;
      out[i] = c[0];
      out[i + 1] = c[1];
      out[i + 2] = c[2];
      out[i + 3] = c[3];
    }
  }
  return out;
}

const List<int> kOpaqueBlack = <int>[0, 0, 0, 255];
const List<int> kOpaqueWhite = <int>[255, 255, 255, 255];

/// Fully transparent. Premultiplied, so every colour channel is necessarily 0 —
/// which is exactly why reading them naively yields black.
const List<int> kTransparent = <int>[0, 0, 0, 0];

int _setBits(Uint8List bits) {
  int n = 0;
  for (final int b in bits) {
    for (int i = 0; i < 8; i++) {
      if (b & (1 << i) != 0) n++;
    }
  }
  return n;
}

void main() {
  group('luminance', () {
    test('opaque black and white map to the extremes', () {
      final Uint8List luma = RasterDither.luminance(
        rgba: rgba(
          2,
          1,
          (int x, int _) => x == 0 ? kOpaqueBlack : kOpaqueWhite,
        ),
        width: 2,
        height: 1,
      );
      expect(luma, <int>[0, 255]);
    });

    test('transparent pixels composite to white, not black', () {
      // The single most expensive bug this pipeline can have: a transparent
      // canvas read naively is (0,0,0) = black, which would burn a whole roll.
      final Uint8List luma = RasterDither.luminance(
        rgba: rgba(1, 1, (_, _) => kTransparent),
        width: 1,
        height: 1,
      );
      expect(luma, <int>[255]);
    });

    test('half-transparent black lands mid-scale', () {
      // Premultiplied 50% black: colour channels already scaled by alpha.
      final Uint8List luma = RasterDither.luminance(
        rgba: rgba(1, 1, (_, _) => <int>[0, 0, 0, 128]),
        width: 1,
        height: 1,
      );
      expect(luma.single, closeTo(127, 1));
    });

    test('rejects a buffer smaller than the declared size', () {
      expect(
        () => RasterDither.luminance(rgba: Uint8List(4), width: 4, height: 4),
        throwsArgumentError,
      );
    });
  });

  group('pack — threshold', () {
    test('produces exact bytes for a black/white split', () {
      final Uint8List luma = Uint8List.fromList(<int>[
        0, 0, 0, 0, 255, 255, 255, 255, //
      ]);
      final Uint8List bits = RasterDither.pack(
        luma: luma,
        sourceWidth: 8,
        sourceHeight: 1,
        targetWidth: 8,
        dithering: PrintlyDithering.threshold,
        threshold: 128,
      );
      // MSB-first: the leftmost pixel is bit 7.
      expect(bits, <int>[0xF0]);
    });

    test('burns strictly below the cutoff', () {
      final Uint8List luma = Uint8List.fromList(<int>[
        127, 128, 129, 0, 255, 0, 255, 0, //
      ]);
      final Uint8List bits = RasterDither.pack(
        luma: luma,
        sourceWidth: 8,
        sourceHeight: 1,
        targetWidth: 8,
        dithering: PrintlyDithering.threshold,
        threshold: 128,
      );
      // 127 burns, 128 does not (the comparison is `<`), 129 does not.
      expect(bits, <int>[0x80 | 0x10 | 0x04 | 0x01]);
    });

    test('crops rows wider than the target', () {
      final Uint8List luma = Uint8List(16); // all black
      final Uint8List bits = RasterDither.pack(
        luma: luma,
        sourceWidth: 16,
        sourceHeight: 1,
        targetWidth: 8,
        dithering: PrintlyDithering.threshold,
        threshold: 128,
      );
      expect(bits.length, 1);
      expect(bits, <int>[0xFF]);
    });

    test('pads narrow rows with white', () {
      final Uint8List luma = Uint8List(4); // 4 black pixels
      final Uint8List bits = RasterDither.pack(
        luma: luma,
        sourceWidth: 4,
        sourceHeight: 1,
        targetWidth: 16,
        dithering: PrintlyDithering.threshold,
        threshold: 128,
      );
      expect(bits.length, 2);
      expect(bits, <int>[0xF0, 0x00]);
    });

    test('rejects a target width that is not byte-aligned', () {
      expect(
        () => RasterDither.pack(
          luma: Uint8List(10),
          sourceWidth: 10,
          sourceHeight: 1,
          targetWidth: 10,
          dithering: PrintlyDithering.threshold,
          threshold: 128,
        ),
        throwsArgumentError,
      );
    });
  });

  group('pack — Floyd-Steinberg', () {
    Uint8List dither(List<int> luma, int w, int h) => RasterDither.pack(
      luma: Uint8List.fromList(luma),
      sourceWidth: w,
      sourceHeight: h,
      targetWidth: w,
      dithering: PrintlyDithering.floydSteinberg,
      threshold: 128,
    );

    test('leaves solid black and solid white untouched', () {
      expect(
        dither(List<int>.filled(64, 0), 8, 8).every((int b) => b == 0xFF),
        isTrue,
      );
      expect(
        dither(List<int>.filled(64, 255), 8, 8).every((int b) => b == 0x00),
        isTrue,
      );
    });

    test('breaks flat mid-grey into a mix of dots', () {
      // The whole point of diffusion: a uniform 50% grey must not collapse to
      // all-white (which a bare threshold at 128 would produce).
      final Uint8List bits = dither(List<int>.filled(256, 128), 16, 16);
      final int set = _setBits(bits);
      expect(set, greaterThan(0));
      expect(set, lessThan(256));
      expect(set, closeTo(128, 48));
    });

    test('is deterministic', () {
      final List<int> luma = List<int>.generate(256, (int i) => (i * 7) % 256);
      expect(dither(luma, 16, 16), dither(luma, 16, 16));
    });

    test('does not diffuse error into the padded region', () {
      // Error pushed past the source edge would darken padding that has no
      // pixels behind it.
      final Uint8List bits = RasterDither.pack(
        luma: Uint8List.fromList(List<int>.filled(8, 128)),
        sourceWidth: 8,
        sourceHeight: 1,
        targetWidth: 16,
        dithering: PrintlyDithering.floydSteinberg,
        threshold: 128,
      );
      expect(bits[1], 0x00, reason: 'padding stays white');
    });

    test('handles a receipt-sized plane without quadratic blow-up', () {
      // Guards the allocation strategy: a List<int> + insertAll implementation
      // would make this test crawl or time out.
      const int w = 384;
      const int h = 1000;
      final Uint8List luma = Uint8List(w * h)..fillRange(0, w * h, 100);
      final Uint8List bits = RasterDither.pack(
        luma: luma,
        sourceWidth: w,
        sourceHeight: h,
        targetWidth: w,
        dithering: PrintlyDithering.floydSteinberg,
        threshold: 128,
      );
      expect(bits.length, (w >> 3) * h);
    });
  });
}

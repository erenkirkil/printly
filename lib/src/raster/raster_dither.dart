import 'dart:typed_data';

import 'printly_dithering.dart';

/// Pixels in, printer bits out.
///
/// Pure integer arithmetic over typed arrays — no `dart:ui`, no Flutter, no
/// allocation beyond the two output buffers and a pair of error rows. Every
/// entry point is a top-level static taking and returning only [Uint8List] and
/// [int], so moving the work to an isolate later is a one-line `compute()` wrap
/// rather than a refactor.
///
/// Not exported: [PrintlyBitmap] is the public door.
abstract final class RasterDither {
  /// Rec. 601 luma weights scaled to 256 so the divide is a shift.
  static const int _rWeight = 77;
  static const int _gWeight = 150;
  static const int _bWeight = 29;

  /// Converts premultiplied RGBA to 8-bit luma, compositing over white paper.
  ///
  /// `dart:ui` hands back **premultiplied** alpha ([ImageByteFormat.rawRgba]),
  /// which makes the white composite a single add:
  ///
  /// ```
  /// straight = premul / a          composite = straight * a + 255 * (1 - a)
  ///                                          = premul + 255 - a
  /// ```
  ///
  /// No multiply, no divide, and no division-by-zero at `a == 0`. That last
  /// case matters: a fully transparent pixel becomes 255 (white), whereas
  /// reading the colour channels naively would yield 0 and print a solid black
  /// receipt — the most expensive bug this pipeline can have.
  ///
  /// Values are clamped on the way out so straight-alpha input passed by
  /// mistake degrades to a washed-out image instead of wrapping around.
  static Uint8List luminance({
    required Uint8List rgba,
    required int width,
    required int height,
  }) {
    final int pixels = width * height;
    if (rgba.length < pixels * 4) {
      throw ArgumentError.value(
        rgba.length,
        'rgba',
        'expected at least ${pixels * 4} bytes for $width x $height',
      );
    }
    final Uint8List luma = Uint8List(pixels);
    for (int p = 0, i = 0; p < pixels; p++, i += 4) {
      final int inverseAlpha = 255 - rgba[i + 3];
      final int y =
          (_rWeight * (rgba[i] + inverseAlpha) +
              _gWeight * (rgba[i + 1] + inverseAlpha) +
              _bWeight * (rgba[i + 2] + inverseAlpha)) >>
          8;
      luma[p] = y > 255 ? 255 : y;
    }
    return luma;
  }

  /// Reduces [luma] to MSB-first packed bits, cropping or white-padding the
  /// rows to [targetWidth] dots.
  ///
  /// [targetWidth] must already be a multiple of 8 (see
  /// `PrintlyBitmap.alignWidth`); the packed row length depends on it, and
  /// `GS v 0` carries that length in its header, so a mismatch prints garbage.
  /// This is exactly where `esc_pos_utils_plus`' own raster path breaks: it
  /// derives the header from the *unaligned* width and then tries to `insertAll`
  /// into a fixed-length list, which throws before it can even produce the wrong
  /// bytes. The output buffer here is allocated once, up front, and only ever
  /// indexed into.
  ///
  /// Bit 1 means "burn this dot". Bit 7 (`0x80`) is the leftmost pixel of each
  /// byte, matching what `GS v 0` expects.
  static Uint8List pack({
    required Uint8List luma,
    required int sourceWidth,
    required int sourceHeight,
    required int targetWidth,
    required PrintlyDithering dithering,
    required int threshold,
  }) {
    if (targetWidth % 8 != 0) {
      throw ArgumentError.value(
        targetWidth,
        'targetWidth',
        'must be a multiple of 8',
      );
    }
    final int widthBytes = targetWidth >> 3;
    final Uint8List bits = Uint8List(widthBytes * sourceHeight);
    final int copyWidth = sourceWidth < targetWidth ? sourceWidth : targetWidth;
    if (copyWidth <= 0 || sourceHeight <= 0) return bits;

    final bool diffuse = dithering == PrintlyDithering.floydSteinberg;

    // Floyd-Steinberg only ever pushes error to (x+1, y) and the three cells
    // below, so two rows of accumulator are enough. A full-plane Int16List for
    // a 384 x 2000 receipt would be 1.5 MB; this is 1.5 KB.
    Int16List current = Int16List(diffuse ? copyWidth : 0);
    Int16List below = Int16List(diffuse ? copyWidth : 0);

    for (int y = 0; y < sourceHeight; y++) {
      final int lumaRow = y * sourceWidth;
      final int bitRow = y * widthBytes;
      for (int x = 0; x < copyWidth; x++) {
        final int value = diffuse
            ? luma[lumaRow + x] + current[x]
            : luma[lumaRow + x];
        final bool burn = value < threshold;
        if (burn) {
          bits[bitRow + (x >> 3)] |= 0x80 >> (x & 7);
        }
        if (diffuse) {
          // What the head cannot reproduce is handed to the neighbours.
          final int error = value - (burn ? 0 : 255);
          if (x + 1 < copyWidth) {
            current[x + 1] += (error * 7) >> 4;
            below[x + 1] += error >> 4;
          }
          if (x > 0) below[x - 1] += (error * 3) >> 4;
          below[x] += (error * 5) >> 4;
        }
      }
      if (diffuse) {
        final Int16List spent = current;
        current = below;
        below = spent..fillRange(0, copyWidth, 0);
      }
    }
    return bits;
  }
}

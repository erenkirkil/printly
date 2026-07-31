import 'dart:typed_data';

import 'printly_dithering.dart';
import 'raster_dither.dart';

/// A one-bit-per-dot image, ready for the printer.
///
/// This is the hand-off point between the two halves of the raster pipeline:
/// producing one needs `dart:ui` and is asynchronous, consuming one is pure
/// synchronous byte work. Keeping the boundary here is what lets
/// `PrintJob.bitmap` stay synchronous and cascadable:
///
/// ```dart
/// final logo = await PrintlyRaster.image(png, width: 384);
/// job..bitmap(logo)..text('...')..cut();
/// ```
///
/// It also makes reuse free. Instances are immutable, so a logo rendered once
/// at startup can be stamped onto every receipt for the rest of the session
/// without touching the rasteriser again.
///
/// `==` is deliberately *not* overridden. A receipt-sized bitmap is tens of
/// kilobytes, and a deep comparison hiding behind `==` would be a silent
/// performance trap in list diffing or widget rebuilds. Instances compare by
/// identity; immutability here is about safe sharing, not value semantics.
class PrintlyBitmap {
  const PrintlyBitmap._({
    required this.width,
    required this.height,
    required this.bits,
  });

  /// An all-white bitmap of the given size — useful as spacing, and as the
  /// neutral value when a render produces nothing.
  factory PrintlyBitmap.blank({required int width, required int height}) {
    final int aligned = alignWidth(width);
    if (height < 0) {
      throw ArgumentError.value(height, 'height', 'must not be negative');
    }
    return PrintlyBitmap._(
      width: aligned,
      height: height,
      bits: Uint8List((aligned >> 3) * height),
    );
  }

  /// Converts a premultiplied RGBA buffer — what `ui.Image.toByteData()`
  /// returns by default — into printable dots.
  ///
  /// [width] is the desired output width in dots and is rounded **down** to a
  /// multiple of 8 (see [alignWidth]). Rows wider than that are cropped from
  /// the right; narrower rows are padded with white.
  ///
  /// [threshold] is the 0–255 cutoff below which a dot is burned. The default
  /// sits at the midpoint; lowering it prints lighter, raising it darker.
  ///
  /// Transparent regions come out white, not black — see
  /// [RasterDither.luminance] for why that is not automatic.
  factory PrintlyBitmap.fromPremultipliedRgba({
    required Uint8List rgba,
    required int sourceWidth,
    required int sourceHeight,
    required int width,
    PrintlyDithering dithering = PrintlyDithering.floydSteinberg,
    int threshold = defaultThreshold,
  }) {
    if (sourceWidth <= 0 || sourceHeight < 0) {
      throw ArgumentError(
        'source must be non-empty: got $sourceWidth x $sourceHeight',
      );
    }
    if (threshold < 0 || threshold > 255) {
      throw ArgumentError.value(threshold, 'threshold', 'must be 0..255');
    }
    final int aligned = alignWidth(width);
    final Uint8List luma = RasterDither.luminance(
      rgba: rgba,
      width: sourceWidth,
      height: sourceHeight,
    );
    return PrintlyBitmap._(
      width: aligned,
      height: sourceHeight,
      bits: RasterDither.pack(
        luma: luma,
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        targetWidth: aligned,
        dithering: dithering,
        threshold: threshold,
      ),
    );
  }

  /// Midpoint cutoff used when no [threshold] is given.
  static const int defaultThreshold = 128;

  /// Narrowest bitmap the format can express: one byte per row.
  static const int minWidth = 8;

  /// Width in dots. Always a multiple of 8.
  final int width;

  /// Height in dots (printed rows).
  final int height;

  /// Packed dots, MSB-first, `1` = burn. Exactly [widthBytes] * [height] long.
  final Uint8List bits;

  /// Bytes per printed row — the value `GS v 0` carries in `xL`/`xH`.
  int get widthBytes => width >> 3;

  /// Total payload size. Worth checking before printing over Bluetooth Classic,
  /// which gives a whole job a single 10-second write budget.
  int get byteLength => bits.length;

  /// Printed height in millimetres, assuming the 203 dpi (8 dots/mm) head that
  /// every supported printer uses.
  double get heightMm => height / 8.0;

  /// Whether this bitmap would emit nothing at all.
  bool get isEmpty => height == 0;

  /// Expands the packed dots back into an opaque RGBA buffer — black where a
  /// dot burns, white where it does not.
  ///
  /// The inverse of [fromPremultipliedRgba], and the only way to *look* at a
  /// bitmap before spending paper on it. Feed the result to
  /// `ui.decodeImageFromPixels` and the preview shows exactly what the head
  /// will burn, dithering and all — which no preview of the source widget or
  /// image can tell you.
  ///
  /// Stays pure Dart deliberately: the caller owns the `dart:ui` step, so this
  /// works in a test or an isolate too.
  Uint8List toRgba() {
    final Uint8List rgba = Uint8List(width * height * 4);
    for (int y = 0; y < height; y++) {
      final int bitRow = y * widthBytes;
      final int pixelRow = y * width;
      for (int x = 0; x < width; x++) {
        final bool burn = bits[bitRow + (x >> 3)] & (0x80 >> (x & 7)) != 0;
        final int i = (pixelRow + x) * 4;
        final int value = burn ? 0 : 255;
        rgba[i] = value;
        rgba[i + 1] = value;
        rgba[i + 2] = value;
        rgba[i + 3] = 255;
      }
    }
    return rgba;
  }

  /// Rounds [width] **down** to a multiple of 8.
  ///
  /// Down, never up: rounding 385 dots up to 392 would exceed a 58 mm head's
  /// 384 and make the printer wrap or clip the row. Losing up to 7 dots off the
  /// right edge is invisible; overflowing is not. Both supported paper widths
  /// (384 and 576 dots) are already multiples of 8, so a full-width bitmap
  /// loses nothing.
  static int alignWidth(int width) {
    if (width < minWidth) {
      throw ArgumentError.value(
        width,
        'width',
        'must be at least $minWidth dots',
      );
    }
    return width - (width % 8);
  }

  @override
  String toString() =>
      'PrintlyBitmap($width x $height dots, $byteLength bytes)';
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';
import 'package:printly/src/raster/raster_encoder.dart';

/// Byte-for-byte `GS v 0` output for a 16x4 checkerboard.
///
/// Deliberately tiny so the whole thing is verifiable by eye against the
/// ESC/POS spec. Regenerate DELIBERATELY — if this constant changes, work out
/// which byte moved and why before touching it. It pins printly's own encoder,
/// which is a separate concern from `print_golden_test.dart` (that one pins the
/// wrapped `esc_pos_utils_plus` generator across dependency bumps).
// dart format off
const List<int> kGoldenRasterBytes = <int>[
  // GS v 0, m = 0 (normal density both axes)
  0x1D, 0x76, 0x30, 0x00,
  // xL xH — 2 bytes per row (16 dots)
  0x02, 0x00,
  // yL yH — 4 rows; yH stays 0 by the 255-row band cap
  0x04, 0x00,
  // rows 0-1: left half burned, right half blank
  0xFF, 0x00,
  0xFF, 0x00,
  // rows 2-3: mirrored
  0x00, 0xFF,
  0x00, 0xFF,
];
// dart format on

/// 16x4 premultiplied RGBA checkerboard with 8-dot squares.
Uint8List checkerboard() {
  const int width = 16;
  const int height = 4;
  final Uint8List out = Uint8List(width * height * 4);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final bool dark = (x < 8) == (y < 2);
      final int value = dark ? 0 : 255;
      final int i = (y * width + x) * 4;
      out[i] = value;
      out[i + 1] = value;
      out[i + 2] = value;
      out[i + 3] = 255;
    }
  }
  return out;
}

void main() {
  test('checkerboard encodes to the golden byte stream', () {
    final PrintlyBitmap bitmap = PrintlyBitmap.fromPremultipliedRgba(
      rgba: checkerboard(),
      sourceWidth: 16,
      sourceHeight: 4,
      width: 16,
      dithering: PrintlyDithering.threshold,
    );
    expect(RasterEncoder.emit(bitmap), kGoldenRasterBytes);
  });

  test('splitting the same bitmap into bands repeats only the header', () {
    final PrintlyBitmap bitmap = PrintlyBitmap.fromPremultipliedRgba(
      rgba: checkerboard(),
      sourceWidth: 16,
      sourceHeight: 4,
      width: 16,
      dithering: PrintlyDithering.threshold,
    );
    expect(RasterEncoder.emit(bitmap, bandHeight: 2), <int>[
      0x1D, 0x76, 0x30, 0x00, 0x02, 0x00, 0x02, 0x00, // band 1: rows 0-1
      0xFF, 0x00, 0xFF, 0x00,
      0x1D, 0x76, 0x30, 0x00, 0x02, 0x00, 0x02, 0x00, // band 2: rows 2-3
      0x00, 0xFF, 0x00, 0xFF,
    ]);
  });
}

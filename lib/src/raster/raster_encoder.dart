import 'printly_bitmap.dart';

/// Turns a [PrintlyBitmap] into `GS v 0` raster commands.
///
/// The command is emitted by hand rather than through `esc_pos_utils_plus`'
/// `imageRaster()`, which is unusable: for any width that is not already a
/// multiple of 8 it replaces the greyscale data with a zero-filled
/// **fixed-length** list and then calls `insertAll` on it, so it throws
/// `UnsupportedError` before it can print anything — and its header is derived
/// from the unaligned width regardless. The `GS ( L` branch has a separate
/// two-byte length overflow. Emitting the eight header bytes here costs less
/// than working around all of that.
///
/// Not exported; `PrintJob.bitmap` is the public door.
abstract final class RasterEncoder {
  /// `GS v 0` — print raster bit image.
  static const List<int> _header = <int>[0x1D, 0x76, 0x30];

  /// Normal density on both axes. The other three values of `m` halve the
  /// horizontal and/or vertical resolution.
  static const int _normalDensity = 0;

  /// Rows per band unless overridden.
  ///
  /// 64 rows is 3 KB at 58 mm — small enough to fit the most cramped printer
  /// buffer in one piece, while the 8-byte header costs 0.26% overhead. It also
  /// puts a band boundary every 8 mm, fine enough to localise a defect on the
  /// paper without being so frequent that a seam artefact would ruin a receipt.
  static const int defaultBandHeight = 64;

  /// Tallest band that can be emitted.
  ///
  /// Capped at 255 so `yH` is always zero. Cheap firmware that ignores the high
  /// byte of a length field is a known failure class — the same one that
  /// required printly to emit QR blocks by hand — and staying under one byte
  /// makes the whole question moot.
  static const int maxBandHeight = 255;

  /// Encodes [bitmap] as one or more `GS v 0` blocks of at most [bandHeight]
  /// rows each.
  ///
  /// Nothing is emitted between bands: no line feed, no spacing command. On the
  /// tested hardware consecutive blocks butt up seamlessly. Should a printer
  /// ever insert a gap, the fix is to wrap the run in `ESC 3 0` / `ESC 2` here
  /// — which is safe to emit directly, because the wrapped generator's style
  /// cache does not track line spacing and so cannot be desynchronised by it.
  ///
  /// An empty bitmap produces no bytes at all.
  static List<int> emit(
    PrintlyBitmap bitmap, {
    int bandHeight = defaultBandHeight,
  }) {
    if (bandHeight < 1 || bandHeight > maxBandHeight) {
      throw ArgumentError.value(
        bandHeight,
        'bandHeight',
        'must be 1..$maxBandHeight rows',
      );
    }
    if (bitmap.isEmpty) return const <int>[];

    final int widthBytes = bitmap.widthBytes;
    final List<int> out = <int>[];
    for (int row = 0; row < bitmap.height; row += bandHeight) {
      final int rows = row + bandHeight <= bitmap.height
          ? bandHeight
          : bitmap.height - row;
      out
        ..addAll(_header)
        ..addAll(<int>[
          _normalDensity,
          widthBytes & 0xFF,
          (widthBytes >> 8) & 0xFF,
          rows, // yL; yH is always zero by the maxBandHeight cap
          0x00,
        ])
        ..addAll(
          bitmap.bits.sublist(row * widthBytes, (row + rows) * widthBytes),
        );
    }
    return out;
  }

  /// Number of blocks [emit] would produce for a bitmap of [height] rows.
  static int bandCount(int height, {int bandHeight = defaultBandHeight}) {
    if (height <= 0) return 0;
    return (height + bandHeight - 1) ~/ bandHeight;
  }
}

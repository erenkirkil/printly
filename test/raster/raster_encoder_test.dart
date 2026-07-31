import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';
import 'package:printly/src/raster/raster_encoder.dart';

/// Walks the emitted stream block by block, returning `(widthBytes, rows)` for
/// each `GS v 0` header and asserting the blocks tile the payload exactly.
List<(int, int)> parseBlocks(List<int> bytes) {
  final List<(int, int)> blocks = <(int, int)>[];
  int at = 0;
  while (at < bytes.length) {
    expect(bytes.sublist(at, at + 3), <int>[
      0x1D,
      0x76,
      0x30,
    ], reason: 'block at $at must start with GS v 0');
    expect(bytes[at + 3], 0, reason: 'm = 0 (normal density)');
    final int widthBytes = bytes[at + 4] | (bytes[at + 5] << 8);
    final int rows = bytes[at + 6] | (bytes[at + 7] << 8);
    blocks.add((widthBytes, rows));
    at += 8 + widthBytes * rows;
  }
  expect(at, bytes.length, reason: 'blocks must tile the stream exactly');
  return blocks;
}

void main() {
  group('emit', () {
    test('a bitmap shorter than one band is a single block', () {
      final List<int> bytes = RasterEncoder.emit(
        PrintlyBitmap.blank(width: 384, height: 8),
      );
      expect(parseBlocks(bytes), <(int, int)>[(48, 8)]);
      expect(bytes.length, 8 + 48 * 8);
    });

    test('splits into bands and carries the remainder in the last one', () {
      final List<int> bytes = RasterEncoder.emit(
        PrintlyBitmap.blank(width: 384, height: 150),
        bandHeight: 64,
      );
      expect(parseBlocks(bytes), <(int, int)>[(48, 64), (48, 64), (48, 22)]);
    });

    test('yH is zero in every band', () {
      // The 255-row cap exists to keep the high height byte out of play, so
      // firmware that ignores it cannot truncate a band.
      final List<int> bytes = RasterEncoder.emit(
        PrintlyBitmap.blank(width: 384, height: 1000),
        bandHeight: RasterEncoder.maxBandHeight,
      );
      int at = 0;
      while (at < bytes.length) {
        expect(bytes[at + 7], 0, reason: 'yH at $at');
        final int widthBytes = bytes[at + 4] | (bytes[at + 5] << 8);
        at += 8 + widthBytes * (bytes[at + 6] | (bytes[at + 7] << 8));
      }
    });

    test('emits nothing between bands', () {
      const int rows = 4;
      final List<int> bytes = RasterEncoder.emit(
        PrintlyBitmap.blank(width: 16, height: rows * 3),
        bandHeight: rows,
      );
      const int block = 8 + 2 * rows;
      expect(bytes.length, block * 3, reason: 'no separators, no line feeds');
    });

    test('an empty bitmap emits nothing', () {
      expect(
        RasterEncoder.emit(PrintlyBitmap.blank(width: 384, height: 0)),
        isEmpty,
      );
    });

    test('band payloads follow the source rows in order', () {
      final PrintlyBitmap bitmap = PrintlyBitmap.fromPremultipliedRgba(
        rgba: _rowPattern(),
        sourceWidth: 8,
        sourceHeight: 4,
        width: 8,
        dithering: PrintlyDithering.threshold,
      );
      final List<int> bytes = RasterEncoder.emit(bitmap, bandHeight: 2);
      // Two blocks of two rows: rows 0,1 then rows 2,3.
      expect(bytes.sublist(8, 10), <int>[0xFF, 0x00]);
      expect(bytes.sublist(18, 20), <int>[0xFF, 0x00]);
    });

    test('rejects a band height outside 1..255', () {
      final PrintlyBitmap bitmap = PrintlyBitmap.blank(width: 8, height: 8);
      expect(
        () => RasterEncoder.emit(bitmap, bandHeight: 0),
        throwsArgumentError,
      );
      expect(
        () => RasterEncoder.emit(bitmap, bandHeight: 256),
        throwsArgumentError,
      );
    });

    test('80 mm paper widens the header, not the band count', () {
      final List<int> bytes = RasterEncoder.emit(
        PrintlyBitmap.blank(width: 576, height: 64),
      );
      expect(parseBlocks(bytes), <(int, int)>[(72, 64)]);
    });
  });

  group('bandCount', () {
    test('matches what emit produces', () {
      for (final int height in <int>[1, 63, 64, 65, 150, 1000]) {
        final List<int> bytes = RasterEncoder.emit(
          PrintlyBitmap.blank(width: 8, height: height),
        );
        expect(RasterEncoder.bandCount(height), parseBlocks(bytes).length);
      }
    });

    test('an empty bitmap has no bands', () {
      expect(RasterEncoder.bandCount(0), 0);
    });
  });
}

/// 8x4 premultiplied RGBA: rows 0 and 2 black, rows 1 and 3 white.
Uint8List _rowPattern() {
  final Uint8List out = Uint8List(8 * 4 * 4);
  for (int y = 0; y < 4; y++) {
    final int value = y.isEven ? 0 : 255;
    for (int x = 0; x < 8; x++) {
      final int i = (y * 8 + x) * 4;
      out[i] = value;
      out[i + 1] = value;
      out[i + 2] = value;
      out[i + 3] = 255;
    }
  }
  return out;
}

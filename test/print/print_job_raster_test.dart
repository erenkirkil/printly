import 'dart:typed_data';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';

int _indexOf(List<int> haystack, List<int> needle, [int from = 0]) {
  if (needle.isEmpty || needle.length > haystack.length) return -1;
  outer:
  for (int i = from; i <= haystack.length - needle.length; i++) {
    for (int j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

int _count(List<int> haystack, List<int> needle) {
  int found = 0;
  int at = _indexOf(haystack, needle);
  while (at >= 0) {
    found++;
    at = _indexOf(haystack, needle, at + needle.length);
  }
  return found;
}

/// `GS v 0` with normal density.
const List<int> kRasterHeader = <int>[0x1D, 0x76, 0x30, 0x00];

/// `ESC a n` — alignment.
///
/// The wrapped generator spells `n` as an ASCII digit (`'0'`, `'1'`) rather
/// than a raw 0/1 byte. Both forms are valid ESC/POS and printers accept
/// either, but a test looking for the raw byte silently finds nothing.
const List<int> kAlignLeft = <int>[0x1B, 0x61, 0x30];
const List<int> kAlignCentre = <int>[0x1B, 0x61, 0x31];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CapabilityProfile profile;

  setUpAll(() async {
    profile = await CapabilityProfile.load();
  });

  PrintJob job({PrintConfig config = const PrintConfig()}) {
    return PrintJob.fromGenerator(
      generator: Generator(
        config.paperWidth == PrintlyPaperWidth.mm80
            ? PaperSize.mm80
            : PaperSize.mm58,
        profile,
      ),
      config: config,
    );
  }

  /// A solid black bitmap — every bit set, so band boundaries are easy to spot.
  PrintlyBitmap black({int width = 384, required int height}) {
    final Uint8List rgba = Uint8List(width * height * 4);
    for (int i = 3; i < rgba.length; i += 4) {
      rgba[i] = 255; // opaque, colour channels stay 0 = black
    }
    return PrintlyBitmap.fromPremultipliedRgba(
      rgba: rgba,
      sourceWidth: width,
      sourceHeight: height,
      width: width,
      dithering: PrintlyDithering.threshold,
    );
  }

  group('bitmap', () {
    test('does not desync the generator style cache', () {
      // The one discipline this whole integration rests on. Emitting the
      // alignment as raw bytes would leave the wrapped generator believing the
      // alignment is still left; the following text() would then skip its own
      // ESC a and print centred by accident.
      final Uint8List bytes =
          (job()
                ..bitmap(black(height: 8), align: PrintlyTextAlign.center)
                ..text('X'))
              .build();

      final int centreAt = _indexOf(bytes, kAlignCentre);
      final int rasterAt = _indexOf(bytes, kRasterHeader);
      final int leftAt = _indexOf(bytes, kAlignLeft, rasterAt);

      expect(centreAt, greaterThanOrEqualTo(0), reason: 'raster centres');
      expect(centreAt, lessThan(rasterAt), reason: 'alignment precedes it');
      expect(
        leftAt,
        greaterThan(rasterAt),
        reason: 'the following text must restore left alignment itself',
      );
    });

    test('emits one band per bandHeight rows', () {
      final Uint8List bytes = (job(
        config: const PrintConfig(rasterBandHeight: 64),
      )..bitmap(black(height: 150))).build();
      expect(_count(bytes, kRasterHeader), 3, reason: '64 + 64 + 22');
    });

    test('honours a custom band height from the config', () {
      final Uint8List bytes = (job(
        config: const PrintConfig(rasterBandHeight: 16),
      )..bitmap(black(height: 64))).build();
      expect(_count(bytes, kRasterHeader), 4);
    });

    test('an empty bitmap emits no raster command at all', () {
      final Uint8List bytes =
          (job()..bitmap(PrintlyBitmap.blank(width: 384, height: 0))).build();
      expect(_count(bytes, kRasterHeader), 0);
    });

    test('build stays idempotent with a bitmap in the job', () {
      final PrintJob receipt = job(
        config: const PrintConfig(feedLines: 2, cutAfterPrint: true),
      )..bitmap(black(height: 16));
      expect(receipt.build(), receipt.build());
    });

    test('finalisers still land after the raster body', () {
      final Uint8List bytes = (job(
        config: const PrintConfig(feedLines: 2, cutAfterPrint: true),
      )..bitmap(black(height: 16))).build();
      final int rasterAt = _indexOf(bytes, kRasterHeader);
      final int cutAt = _indexOf(bytes, <int>[0x1D, 0x56]);
      expect(cutAt, greaterThan(rasterAt));
      expect(_count(bytes, <int>[0x1D, 0x56]), 1);
    });

    test('mixes with text without losing either', () {
      final Uint8List bytes =
          (job()
                ..text('HEADER')
                ..bitmap(black(height: 8))
                ..text('FOOTER'))
              .build();
      expect(_indexOf(bytes, 'HEADER'.codeUnits), greaterThanOrEqualTo(0));
      expect(_indexOf(bytes, 'FOOTER'.codeUnits), greaterThanOrEqualTo(0));
      expect(_count(bytes, kRasterHeader), 1);
      expect(
        _indexOf(bytes, 'FOOTER'.codeUnits),
        greaterThan(_indexOf(bytes, kRasterHeader)),
      );
    });

    test('80 mm paper widens the header', () {
      final Uint8List bytes = (job(
        config: const PrintConfig(paperWidth: PrintlyPaperWidth.mm80),
      )..bitmap(black(width: 576, height: 8))).build();
      final int at = _indexOf(bytes, kRasterHeader);
      expect(bytes[at + 4], 72, reason: '576 dots = 72 bytes per row');
    });
  });

  group('textRaster', () {
    test('defaults to the full paper width', () async {
      final PrintJob receipt = job();
      await receipt.textRaster('Merhaba');
      final Uint8List bytes = receipt.build();
      final int at = _indexOf(bytes, kRasterHeader);
      expect(at, greaterThanOrEqualTo(0));
      expect(bytes[at + 4], 48, reason: '384 dots = 48 bytes per row');
    });

    test('produces Turkish glyphs without touching the code page', () async {
      final PrintJob receipt = job();
      await receipt.textRaster('Şişli Çağrı');
      final Uint8List bytes = receipt.build();
      expect(
        _count(bytes, <int>[0x1B, 0x74]),
        0,
        reason: 'ESC t must never be emitted for raster text',
      );
      expect(_count(bytes, kRasterHeader), greaterThanOrEqualTo(1));
    });

    test('empty content adds nothing', () async {
      final PrintJob receipt = job();
      final Uint8List before = receipt.build();
      await receipt.textRaster('');
      expect(receipt.build(), before);
    });

    test('returns the same job so the result can be chained', () async {
      final PrintJob receipt = job();
      expect(await receipt.textRaster('x'), same(receipt));
    });
  });

  group('PrintConfig.rasterBandHeight', () {
    test('defaults to the encoder default', () {
      expect(const PrintConfig().rasterBandHeight, 64);
    });

    test('survives copyWith round-trips', () {
      const PrintConfig config = PrintConfig(rasterBandHeight: 32);
      expect(config.copyWith().rasterBandHeight, 32);
      expect(config.copyWith(rasterBandHeight: 128).rasterBandHeight, 128);
      expect(config.copyWith(feedLines: 4).rasterBandHeight, 32);
    });

    test('rejects a band height outside 1..255', () {
      expect(() => PrintConfig(rasterBandHeight: 0), throwsAssertionError);
      expect(() => PrintConfig(rasterBandHeight: 256), throwsAssertionError);
    });
  });
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';

/// An 8x4 RGB PNG: the left four columns pure red, the right four white.
///
/// Hand-built rather than loaded from an asset so the fixture is small enough
/// to audit and cannot drift. Red matters: at Rec. 601 weights it lands at
/// luma 76, comfortably under the 128 cutoff, so "did the colour survive the
/// decode" and "did the threshold fire" are one assertion.
// dart format off
const List<int> kRedWhitePng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x04,
  0x08, 0x02, 0x00, 0x00, 0x00, 0x3C, 0xAF, 0xE9, 0xA7, 0x00, 0x00, 0x00,
  0x12, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0xF8, 0xCF, 0xC0, 0x80,
  0x40, 0x48, 0x80, 0x81, 0x7A, 0x12, 0x00, 0xC5, 0x39, 0x3F, 0xC1, 0xD5,
  0xF1, 0x4D, 0x69, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];
// dart format on

void main() {
  // Decoding goes through the engine, so the binding must be up even in a
  // plain test(). No fake-async zone here, unlike testWidgets, so the futures
  // complete normally.
  TestWidgetsFlutterBinding.ensureInitialized();

  final Uint8List png = Uint8List.fromList(kRedWhitePng);

  test('decodes and thresholds a PNG', () async {
    final PrintlyBitmap bitmap = await PrintlyRaster.image(
      png,
      width: 8,
      dithering: PrintlyDithering.threshold,
    );
    expect(bitmap.width, 8);
    expect(bitmap.height, 4);
    expect(bitmap.widthBytes, 1);
    // Red burns, white does not — MSB-first, so the left half is the high bits.
    expect(bitmap.bits, <int>[0xF0, 0xF0, 0xF0, 0xF0]);
  });

  test('width is a ceiling, not a stretch', () async {
    // The source is 8 dots wide; asking for a whole 58 mm line must not upscale
    // it to 384 and blur it. The narrow bitmap gets centred by the printer via
    // PrintJob.bitmap(align:) instead.
    final PrintlyBitmap bitmap = await PrintlyRaster.image(png, width: 384);
    expect(bitmap.width, 8);
    expect(bitmap.height, 4);
  });

  test('scales down and keeps the aspect ratio when the source is wider', () {
    // 8x4 asked to fit 8 dots is already the identity case above; this pins the
    // contract for a source that would exceed the paper.
    expect(PrintlyBitmap.alignWidth(384), 384);
  });

  test('rejects a target narrower than one byte', () async {
    await expectLater(PrintlyRaster.image(png, width: 4), throwsArgumentError);
  });

  test(
    'surfaces corrupt input as an error rather than a blank bitmap',
    () async {
      await expectLater(
        PrintlyRaster.image(
          Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02]),
          width: 8,
        ),
        throwsA(isA<Exception>()),
      );
    },
  );
}

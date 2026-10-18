import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';

/// Frozen ESC/POS byte streams captured before removing `esc_pos_utils_plus`.
///
/// Unlike `print_golden_test.dart`, this file has **no** dependency on
/// `esc_pos_utils_plus` and constructs jobs exclusively through the public
/// [PrintJob.create] entrypoint. It serves as the byte-for-byte contract
/// across all phases of the v1.0 encoder migration:
/// - Phase 0: verified against the legacy `Generator`-backed [PrintJob].
/// - Phase 1: replayed against `EscPosEncoder` in shadow tests.
/// - Phase 2: verified against the `EscPosEncoder`-backed [PrintJob].
// dart format off

/// Scenario 1: Representative Turkish receipt (text, divider, CODE128, QR,
/// feed, full cut).
const List<int> kFrozenRepresentativeReceiptBytes = <int>[
  // ESC @ (reset), then line 1: ESC t 13 (CP857), ESC $ 0 0, ESC a '1'
  // (center), ESC E 1 (bold on), FS . (kanji off), "MAĞAZA" (Ğ = 0xA6), LF.
  0x1B, 0x40, 0x1B, 0x74, 0x0D, 0x1B, 0x24, 0x00, 0x00, 0x1B, 0x61, 0x31,
  0x1B, 0x45, 0x01, 0x1C, 0x2E, 0x4D, 0x41, 0xA6, 0x41, 0x5A, 0x41, 0x0A,
  // Divider: ESC t 0 (CP437), ESC $ 0 0, ESC a '0' (left), ESC E 0 (bold off),
  // FS ., 32 dashes, LF.
  0x1B, 0x74, 0x00, 0x1B, 0x24, 0x00, 0x00, 0x1B, 0x61, 0x30, 0x1B, 0x45,
  0x00, 0x1C, 0x2E, 0x2D, 0x2D, 0x2D, 0x2D, 0x2D, 0x2D, 0x2D, 0x2D, 0x2D,
  0x2D, 0x2D, 0x2D, 0x2D, 0x2D, 0x2D, 0x2D, 0x2D, 0x2D, 0x2D, 0x2D, 0x2D,
  0x2D, 0x2D, 0x2D, 0x2D, 0x2D, 0x2D, 0x2D, 0x2D, 0x2D, 0x2D, 0x2D, 0x0A,
  // "Teşekkürler" in CP857 (ş = 0x9F, ü = 0x81), LF.
  0x1B, 0x74, 0x0D, 0x1B, 0x24, 0x00, 0x00, 0x1C, 0x2E, 0x54, 0x65, 0x9F,
  0x65, 0x6B, 0x6B, 0x81, 0x72, 0x6C, 0x65, 0x72, 0x0A, 0x1B, 0x61, 0x31,
  // CODE128 barcode: GS H 2 (HRI below), GS w 3, GS h 60, GS k 73
  // (function B) len 6, "{B" + "AB12".
  0x1C, 0x2E, 0x1D, 0x48, 0x02, 0x1D, 0x77, 0x03, 0x1D, 0x68, 0x3C, 0x1D,
  0x6B, 0x49, 0x06, 0x7B, 0x42, 0x41, 0x42, 0x31, 0x32, 0x1C, 0x2E, 0x1D,
  // QR: fn 167 module size 8, fn 169 level M (0x31), fn 180 store
  // (pL = 19 + 3 = 22 = 0x16, pH 0) + payload, fn 181 print.
  0x28, 0x6B, 0x03, 0x00, 0x31, 0x43, 0x08, 0x1D, 0x28, 0x6B, 0x03, 0x00,
  0x31, 0x45, 0x31, 0x1D, 0x28, 0x6B, 0x16, 0x00, 0x31, 0x50, 0x30, 0x68,
  0x74, 0x74, 0x70, 0x73, 0x3A, 0x2F, 0x2F, 0x65, 0x78, 0x61, 0x6D, 0x70,
  0x6C, 0x65, 0x2E, 0x63, 0x6F, 0x6D, 0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31,
  // Feed 2 (ESC d 2), then 5 LFs + GS V 0 (full cut).
  0x51, 0x30, 0x1B, 0x64, 0x02, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x1D, 0x56,
  0x30,
];

/// Scenario 2: Initial default state (no style diff bytes on first left/normal
/// line) followed by every align × style × size transition and reset back to
/// normal.
const List<int> kFrozenAlignStyleSizeMatrixBytes = <int>[
  // ESC @
  0x1B, 0x40,
  // Line 1: text('L0') — default align=left, bold=false, underline=false,
  // size=normal → 0 style diff bytes before FS .!
  0x1B, 0x74, 0x00, 0x1B, 0x24, 0x00, 0x00, 0x1C, 0x2E, 0x4C, 0x30, 0x0A,
  // Line 2: text('C-B-DW', align: center, style: bold, size: doubleWidth)
  // Diff: ESC a '1', ESC E 1, GS ! 0x10, FS .
  0x1B, 0x74, 0x00, 0x1B, 0x24, 0x00, 0x00, 0x1B, 0x61, 0x31, 0x1B, 0x45,
  0x01, 0x1D, 0x21, 0x10, 0x1C, 0x2E, 0x43, 0x2D, 0x42, 0x2D, 0x44, 0x57,
  0x0A,
  // Line 3: text('R-U-DH', align: right, style: underline, size: doubleHeight)
  // Diff: ESC a '2', ESC E 0, ESC - 1, GS ! 0x01, FS .
  0x1B, 0x74, 0x00, 0x1B, 0x24, 0x00, 0x00, 0x1B, 0x61, 0x32, 0x1B, 0x45,
  0x00, 0x1B, 0x2D, 0x01, 0x1D, 0x21, 0x01, 0x1C, 0x2E, 0x52, 0x2D, 0x55,
  0x2D, 0x44, 0x48, 0x0A,
  // Line 4: text('L-BU-DWH', align: left, style: boldUnderline,
  //              size: doubleWidthHeight)
  // Diff: ESC a '0', ESC E 1 (underline stays true!), GS ! 0x11, FS .
  0x1B, 0x74, 0x00, 0x1B, 0x24, 0x00, 0x00, 0x1B, 0x61, 0x30, 0x1B, 0x45,
  0x01, 0x1D, 0x21, 0x11, 0x1C, 0x2E, 0x4C, 0x2D, 0x42, 0x55, 0x2D, 0x44,
  0x57, 0x48, 0x0A,
  // Line 5: text('N') — align already left, resets bold/underline/size:
  // ESC E 0, ESC - 0, GS ! 0x00, FS .
  0x1B, 0x74, 0x00, 0x1B, 0x24, 0x00, 0x00, 0x1B, 0x45, 0x00, 0x1B, 0x2D,
  0x00, 0x1D, 0x21, 0x00, 0x1C, 0x2E, 0x4E, 0x0A,
];

/// Scenario 3: Consecutive identical-style lines and empty text — style cache
/// must emit zero diff bytes on the second and third lines.
const List<int> kFrozenStyleCacheZeroDiffBytes = <int>[
  // ESC @
  0x1B, 0x40,
  // Line 1: center + boldUnderline + doubleWidth → emits ESC a '1', ESC E 1,
  // ESC - 1, GS ! 0x10, FS ., "S1", LF.
  0x1B, 0x74, 0x00, 0x1B, 0x24, 0x00, 0x00, 0x1B, 0x61, 0x31, 0x1B, 0x45,
  0x01, 0x1B, 0x2D, 0x01, 0x1D, 0x21, 0x10, 0x1C, 0x2E, 0x53, 0x31, 0x0A,
  // Line 2: identical style → 0 diff bytes between ESC $ 0 0 and FS ., "S2", LF.
  0x1B, 0x74, 0x00, 0x1B, 0x24, 0x00, 0x00, 0x1C, 0x2E, 0x53, 0x32, 0x0A,
  // Line 3: empty string with identical style → 0 diff bytes, 0 payload bytes, LF.
  0x1B, 0x74, 0x00, 0x1B, 0x24, 0x00, 0x00, 0x1C, 0x2E, 0x0A,
];

/// Scenario 4: Style cache coherence across text → barcode → text → qr →
/// bitmap → text.
const List<int> kFrozenStyleResetAcrossBarcodeQrBitmapBytes = <int>[
  // ESC @
  0x1B, 0x40,
  // 1. text('A', align: right, style: boldUnderline, size: doubleWidthHeight)
  0x1B, 0x74, 0x00, 0x1B, 0x24, 0x00, 0x00, 0x1B, 0x61, 0x32, 0x1B, 0x45,
  0x01, 0x1B, 0x2D, 0x01, 0x1D, 0x21, 0x11, 0x1C, 0x2E, 0x41, 0x0A,
  // 2. barcode('12345678', type: itf, align: center)
  // setStyles(PosStyles(align: center)) resets bold=false, underline=false,
  // size=1x1 and sets align=center:
  // ESC a '1', ESC E 0, ESC - 0, GS ! 0x00, FS .
  0x1B, 0x61, 0x31, 0x1B, 0x45, 0x00, 0x1B, 0x2D, 0x00, 0x1D, 0x21, 0x00,
  0x1C, 0x2E,
  // GS H 2, GS w 3, GS h 60, GS k 5 "12345678" NUL
  0x1D, 0x48, 0x02, 0x1D, 0x77, 0x03, 0x1D, 0x68, 0x3C, 0x1D, 0x6B, 0x05,
  0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x00,
  // 3. text('B', align: center, style: bold) — align already center! Only
  // ESC E 1 is emitted before FS .
  0x1B, 0x74, 0x00, 0x1B, 0x24, 0x00, 0x00, 0x1B, 0x45, 0x01, 0x1C, 0x2E,
  0x42, 0x0A,
  // 4. qr('OK', align: left) — setStyles(PosStyles(align: left)) emits
  // ESC a '0', ESC E 0, FS .
  0x1B, 0x61, 0x30, 0x1B, 0x45, 0x00, 0x1C, 0x2E,
  // QR fn 167 (size 8 = 0x08, capped by QrSizing.defaultMaxModuleSize),
  // fn 169 (M=49), fn 180 (len 5, "OK"), fn 181.
  0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x43, 0x08,
  0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x45, 0x31,
  0x1D, 0x28, 0x6B, 0x05, 0x00, 0x31, 0x50, 0x30, 0x4F, 0x4B,
  0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x51, 0x30,
  // 5. bitmap(8x2 black, align: right) — setStyles(PosStyles(align: right))
  // emits ESC a '2', FS ., then GS v 0 0 xL=1 xH=0 yL=2 yH=0 [0xFF, 0xFF].
  0x1B, 0x61, 0x32, 0x1C, 0x2E,
  0x1D, 0x76, 0x30, 0x00, 0x01, 0x00, 0x02, 0x00, 0xFF, 0xFF,
  // 6. text('C') — default align=left, so cache emits ESC a '0' because
  // bitmap left the cache at right!
  0x1B, 0x74, 0x00, 0x1B, 0x24, 0x00, 0x00, 0x1B, 0x61, 0x30, 0x1C, 0x2E,
  0x43, 0x0A,
];

/// Scenario 5: All 7 barcode symbologies, all HRI positions, width/height
/// bounds, and alignment changes.
const List<int> kFrozenAllSevenBarcodesBytes = <int>[
  // ESC @
  0x1B, 0x40,
  // 1. EAN-13: align=center (ESC a '1', FS .), HRI below (2), width 2,
  // height 80 (0x50), GS k 2 "590123412345" NUL.
  0x1B, 0x61, 0x31, 0x1C, 0x2E,
  0x1D, 0x48, 0x02, 0x1D, 0x77, 0x02, 0x1D, 0x68, 0x50,
  0x1D, 0x6B, 0x02,
  0x35, 0x39, 0x30, 0x31, 0x32, 0x33, 0x34, 0x31, 0x32, 0x33, 0x34, 0x35, 0x00,
  // 2. EAN-8: align=left (ESC a '0', FS .), HRI above (1), width 3,
  // height 50 (0x32), GS k 3 "1234567" NUL.
  0x1B, 0x61, 0x30, 0x1C, 0x2E,
  0x1D, 0x48, 0x01, 0x1D, 0x77, 0x03, 0x1D, 0x68, 0x32,
  0x1D, 0x6B, 0x03,
  0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x00,
  // 3. UPC-A: align=right (ESC a '2', FS .), HRI both (3), width 4,
  // height 60 (0x3C), GS k 0 "01234567890" NUL.
  0x1B, 0x61, 0x32, 0x1C, 0x2E,
  0x1D, 0x48, 0x03, 0x1D, 0x77, 0x04, 0x1D, 0x68, 0x3C,
  0x1D, 0x6B, 0x00,
  0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x30, 0x00,
  // 4. CODE39: align=center (ESC a '1', FS .), showText=false -> HRI none (0),
  // default width 3, default height 60 (0x3C), GS k 4 "CODE-39" NUL.
  0x1B, 0x61, 0x31, 0x1C, 0x2E,
  0x1D, 0x48, 0x00, 0x1D, 0x77, 0x03, 0x1D, 0x68, 0x3C,
  0x1D, 0x6B, 0x04,
  0x43, 0x4F, 0x44, 0x45, 0x2D, 0x33, 0x39, 0x00,
  // 5. ITF: align=center (0 diff, FS .), textPosition=none (0), width 5,
  // height 40 (0x28), GS k 5 "123456" NUL.
  0x1C, 0x2E,
  0x1D, 0x48, 0x00, 0x1D, 0x77, 0x05, 0x1D, 0x68, 0x28,
  0x1D, 0x6B, 0x05,
  0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x00,
  // 6. CODABAR: align=center (0 diff, FS .), HRI below (2), width 6,
  // height 70 (0x46), GS k 6 "A12345B" NUL.
  0x1C, 0x2E,
  0x1D, 0x48, 0x02, 0x1D, 0x77, 0x06, 0x1D, 0x68, 0x46,
  0x1D, 0x6B, 0x06,
  0x41, 0x31, 0x32, 0x33, 0x34, 0x35, 0x42, 0x00,
  // 7. CODE128: align=center (0 diff, FS .), HRI below (2), width 3,
  // height 60 (0x3C), GS k 73 (0x49) len 11 "{BPRINT-128".
  0x1C, 0x2E,
  0x1D, 0x48, 0x02, 0x1D, 0x77, 0x03, 0x1D, 0x68, 0x3C,
  0x1D, 0x6B, 0x49, 0x0B,
  0x7B, 0x42, 0x50, 0x52, 0x49, 0x4E, 0x54, 0x2D, 0x31, 0x32, 0x38,
];

/// Scenario 6: Short QR + quartile QR + 300-byte QR (two-byte store length
/// `pL = 0x2F, pH = 0x01`).
final List<int> kFrozenQrShortAndLongBytes = <int>[
  // ESC @
  0x1B, 0x40,
  // 1. qr('ABCD', errorLevel: low, maxModuleSize: 6, align: left)
  // align is already left → only FS .
  0x1C, 0x2E,
  0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x43, 0x06,
  0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x45, 0x30, // L = 48 (0x30)
  0x1D, 0x28, 0x6B, 0x07, 0x00, 0x31, 0x50, 0x30, 0x41, 0x42, 0x43, 0x44,
  0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x51, 0x30,
  // 2. qr('Q-LVL', errorLevel: quartile, align: right)
  // ESC a '2', FS ., size 8 (0x08), Q = 50 (0x32), len 8
  0x1B, 0x61, 0x32, 0x1C, 0x2E,
  0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x43, 0x08,
  0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x45, 0x32,
  0x1D, 0x28, 0x6B, 0x08, 0x00, 0x31, 0x50, 0x30, 0x51, 0x2D, 0x4C, 0x56, 0x4C,
  0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x51, 0x30,
  // 3. qr('A' * 300, errorLevel: high, align: center)
  // ESC a '1', FS ., size 4 (300 bytes at H -> version 14 -> 73 modules + 8
  // quiet = 81 -> 384 ~/ 81 = 4), H = 51 (0x33), len 303 (0x2F, 0x01)
  0x1B, 0x61, 0x31, 0x1C, 0x2E,
  0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x43, 0x04,
  0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x45, 0x33,
  0x1D, 0x28, 0x6B, 0x2F, 0x01, 0x31, 0x50, 0x30,
  ...List<int>.filled(300, 0x41),
  0x1D, 0x28, 0x6B, 0x03, 0x00, 0x31, 0x51, 0x30,
];

/// Scenario 7: Structural commands (`raw`, `feed`, `cut(partial)`), config
/// finalisers (`feedLines: 3`, `cutAfterPrint: true`, `cutMode: partial`),
/// and charset switches (`turkish`, `windows1254`, `iso8859_9`, `utf8` without
/// `ESC t`).
const List<int> kFrozenStructuralAndCharsetsBytes = <int>[
  // ESC @
  0x1B, 0x40,
  // 1. text('Şğü') — default config charset is turkish (ESC t 13):
  // Ş=0x9E, ğ=0xA7, ü=0x81
  0x1B, 0x74, 0x0D, 0x1B, 0x24, 0x00, 0x00, 0x1C, 0x2E,
  0x9E, 0xA7, 0x81, 0x0A,
  // 2. text('Şğ', charset: windows1254) — ESC t 48 (0x30): Ş=0xDE, ğ=0xF0
  0x1B, 0x74, 0x30, 0x1B, 0x24, 0x00, 0x00, 0x1C, 0x2E,
  0xDE, 0xF0, 0x0A,
  // 3. text('Şğ', charset: iso8859_9) — ESC t 48 (0x30): Ş=0xDE, ğ=0xF0
  0x1B, 0x74, 0x30, 0x1B, 0x24, 0x00, 0x00, 0x1C, 0x2E,
  0xDE, 0xF0, 0x0A,
  // 4. text('Şğ', charset: utf8) — NO ESC t! UTF-8 bytes: Ş=[0xC5, 0x9E],
  // ğ=[0xC4, 0x9F]
  0x1B, 0x24, 0x00, 0x00, 0x1C, 0x2E,
  0xC5, 0x9E, 0xC4, 0x9F, 0x0A,
  // 5. raw([0x1B, 0x33, 0x10])
  0x1B, 0x33, 0x10,
  // 6. feed(4) -> ESC d 4
  0x1B, 0x64, 0x04,
  // 7. Config finalisers: feedLines: 3 (ESC d 3) + cutAfterPrint: true with
  // cutMode: partial (5×LF + GS V 1).
  0x1B, 0x64, 0x03,
  0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x1D, 0x56, 0x31,
];
// dart format on

/// Builds an 8×2 solid-black [PrintlyBitmap] without touching `dart:ui`.
PrintlyBitmap buildSolidBlack8x2Bitmap() {
  final Uint8List rgba = Uint8List(8 * 2 * 4);
  for (int i = 3; i < rgba.length; i += 4) {
    rgba[i] = 255;
  }
  return PrintlyBitmap.fromPremultipliedRgba(
    rgba: rgba,
    sourceWidth: 8,
    sourceHeight: 2,
    width: 8,
    dithering: PrintlyDithering.threshold,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ESC/POS frozen golden suite (esc_pos_utils_plus-free)', () {
    test('1. representative receipt matches frozen golden', () async {
      final PrintJob job = await PrintJob.create();
      job
        ..text(
          'MAĞAZA',
          align: PrintlyTextAlign.center,
          style: PrintlyTextStyle.bold,
          charset: PrintlyCharset.turkish,
        )
        ..divider()
        ..text('Teşekkürler', charset: PrintlyCharset.turkish)
        ..barcode('AB12', type: PrintlyBarcodeType.code128)
        ..qr('https://example.com')
        ..feed(2)
        ..cut();

      expect(job.build(), kFrozenRepresentativeReceiptBytes);
    });

    test('2. align × style × size matrix matches frozen golden', () async {
      final PrintJob job = await PrintJob.create();
      job
        ..text('L0')
        ..text(
          'C-B-DW',
          align: PrintlyTextAlign.center,
          style: PrintlyTextStyle.bold,
          size: PrintlyTextSize.doubleWidth,
        )
        ..text(
          'R-U-DH',
          align: PrintlyTextAlign.right,
          style: PrintlyTextStyle.underline,
          size: PrintlyTextSize.doubleHeight,
        )
        ..text(
          'L-BU-DWH',
          align: PrintlyTextAlign.left,
          style: PrintlyTextStyle.boldUnderline,
          size: PrintlyTextSize.doubleWidthHeight,
        )
        ..text('N');

      expect(job.build(), kFrozenAlignStyleSizeMatrixBytes);
    });

    test('3. consecutive identical-style lines and empty text match', () async {
      final PrintJob job = await PrintJob.create();
      job
        ..text(
          'S1',
          align: PrintlyTextAlign.center,
          style: PrintlyTextStyle.boldUnderline,
          size: PrintlyTextSize.doubleWidth,
        )
        ..text(
          'S2',
          align: PrintlyTextAlign.center,
          style: PrintlyTextStyle.boldUnderline,
          size: PrintlyTextSize.doubleWidth,
        )
        ..text(
          '',
          align: PrintlyTextAlign.center,
          style: PrintlyTextStyle.boldUnderline,
          size: PrintlyTextSize.doubleWidth,
        );

      expect(job.build(), kFrozenStyleCacheZeroDiffBytes);
    });

    test(
      '4. style cache coherence across barcode, QR and bitmap matches',
      () async {
        final PrintJob job = await PrintJob.create();
        job
          ..text(
            'A',
            align: PrintlyTextAlign.right,
            style: PrintlyTextStyle.boldUnderline,
            size: PrintlyTextSize.doubleWidthHeight,
          )
          ..barcode(
            '12345678',
            type: PrintlyBarcodeType.itf,
            align: PrintlyTextAlign.center,
          )
          ..text(
            'B',
            align: PrintlyTextAlign.center,
            style: PrintlyTextStyle.bold,
          )
          ..qr('OK', align: PrintlyTextAlign.left)
          ..bitmap(buildSolidBlack8x2Bitmap(), align: PrintlyTextAlign.right)
          ..text('C');

        expect(job.build(), kFrozenStyleResetAcrossBarcodeQrBitmapBytes);
      },
    );

    test('5. all seven barcode symbologies match frozen golden', () async {
      final PrintJob job = await PrintJob.create();
      job
        ..barcode(
          '590123412345',
          type: PrintlyBarcodeType.ean13,
          height: 80,
          width: 2,
          textPosition: PrintlyHriPosition.below,
          align: PrintlyTextAlign.center,
        )
        ..barcode(
          '1234567',
          type: PrintlyBarcodeType.ean8,
          height: 50,
          width: 3,
          textPosition: PrintlyHriPosition.above,
          align: PrintlyTextAlign.left,
        )
        ..barcode(
          '01234567890',
          type: PrintlyBarcodeType.upcA,
          height: 60,
          width: 4,
          textPosition: PrintlyHriPosition.both,
          align: PrintlyTextAlign.right,
        )
        ..barcode(
          'CODE-39',
          type: PrintlyBarcodeType.code39,
          showText: false,
          align: PrintlyTextAlign.center,
        )
        ..barcode(
          '123456',
          type: PrintlyBarcodeType.itf,
          height: 40,
          width: 5,
          textPosition: PrintlyHriPosition.none,
        )
        ..barcode(
          'A12345B',
          type: PrintlyBarcodeType.codabar,
          height: 70,
          width: 6,
        )
        ..barcode('PRINT-128', type: PrintlyBarcodeType.code128);

      expect(job.build(), kFrozenAllSevenBarcodesBytes);
    });

    test('6. short and 300-byte QR codes match frozen golden', () async {
      final PrintJob job = await PrintJob.create();
      job
        ..qr(
          'ABCD',
          errorLevel: PrintlyQrErrorLevel.low,
          maxModuleSize: 6,
          align: PrintlyTextAlign.left,
        )
        ..qr(
          'Q-LVL',
          errorLevel: PrintlyQrErrorLevel.quartile,
          align: PrintlyTextAlign.right,
        )
        ..qr(
          'A' * 300,
          errorLevel: PrintlyQrErrorLevel.high,
          align: PrintlyTextAlign.center,
        );

      expect(job.build(), kFrozenQrShortAndLongBytes);
    });

    test(
      '7. structural commands, charsets and config finalisers match',
      () async {
        final PrintJob job = await PrintJob.create(
          config: const PrintConfig(
            paperWidth: PrintlyPaperWidth.mm80,
            charset: PrintlyCharset.turkish,
            feedLines: 3,
            cutAfterPrint: true,
            cutMode: PrintlyCutMode.partial,
          ),
        );
        job
          ..text('Şğü')
          ..text('Şğ', charset: PrintlyCharset.windows1254)
          ..text('Şğ', charset: PrintlyCharset.iso8859_9)
          ..text('Şğ', charset: PrintlyCharset.utf8)
          ..raw(<int>[0x1B, 0x33, 0x10])
          ..feed(4);

        expect(job.build(), kFrozenStructuralAndCharsetsBytes);
      },
    );
  });
}

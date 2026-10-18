import 'dart:typed_data';

import 'printly_barcode_type.dart';
import 'printly_cut_mode.dart';
import 'printly_hri_position.dart';
import 'printly_qr_error_level.dart';
import 'printly_text_align.dart';
import 'printly_text_size.dart';
import 'printly_text_style.dart';

/// Pure-Dart ESC/POS command emitter and stateful style cache.
///
/// Replaces the ~20% of `esc_pos_utils_plus`'s `Generator` that printly
/// actually uses (`reset`, `setStyles`, `textEncoded`, `feed`, `cut`,
/// `barcode`, plus `GS ( k` QR emission), eliminating the 66 KB bundled
/// `capabilities.json` asset and its eight transitive dependencies (`image`,
/// `archive`, `html`, `csslib`, `petitparser`, `xml`, `posix`).
///
/// ### Style cache invariants
/// The printer maintains modal state across commands for alignment (`ESC a`),
/// bold (`ESC E`), underline (`ESC -`), and character magnification (`GS !`).
/// To avoid redundant wire bytes on consecutive lines while guaranteeing that
/// styles never leak across commands:
/// 1. **Power-on defaults:** a fresh encoder (or one after [reset]) assumes
///    `align = left`, `bold = false`, `underline = false`, `height = 1`,
///    `width = 1`. Consequently, the first left-aligned normal-styled text
///    line emits **zero** style-diff bytes (`ESC a`/`ESC E`/`ESC -`/`GS !`).
/// 2. **Fixed emission order:** whenever a style differs from the cached state,
///    commands are emitted in the order: alignment (`ESC a`) → bold (`ESC E`) →
///    underline (`ESC -`) → magnification (`GS !`) → Kanji-off (`FS .`).
/// 3. **Non-text commands pass through [setStyles]:** [barcode], [qr], and
///    raster bitmaps call `setStyles(align: align)` with default emphasis and
///    size, which resets bold/underline/size in the cache and updates the
///    cached alignment so subsequent [text] calls restore left alignment if
///    needed. Writing raw `ESC a` bytes outside [setStyles] would desynchronise
///    the cache.
class EscPosEncoder {
  /// Creates a new encoder initialised to the printer power-on style state.
  EscPosEncoder();

  /// Maximum QR payload size in byte mode (QR Version 40, error level L).
  static const int maxQrBytes = 2953;

  // GS ( k — the QR command header shared by all QR functions.
  static const List<int> _qrHeader = <int>[0x1D, 0x28, 0x6B];

  PrintlyTextAlign _align = PrintlyTextAlign.left;
  bool _bold = false;
  bool _underline = false;
  int _heightMultiplier = 1;
  int _widthMultiplier = 1;

  /// Emits `ESC @` (`0x1B 0x40`) to initialise the printer and resets the
  /// internal style cache back to power-on defaults.
  List<int> reset() {
    _align = PrintlyTextAlign.left;
    _bold = false;
    _underline = false;
    _heightMultiplier = 1;
    _widthMultiplier = 1;
    return const <int>[0x1B, 0x40];
  }

  /// Diff-emits style commands required to reach ([align], [style], [size])
  /// from the current cached state, followed by `FS .` (`0x1C 0x2E`, cancel
  /// Kanji mode).
  ///
  /// Omitted parameters default to the printer power-on state (`left`,
  /// `normal`, `1×1`), so calling `setStyles(align: align)` before a barcode,
  /// QR code, or raster bitmap also clears any active bold, underline, or
  /// magnification in both the printer and the cache.
  List<int> setStyles({
    PrintlyTextAlign align = PrintlyTextAlign.left,
    PrintlyTextStyle style = PrintlyTextStyle.normal,
    PrintlyTextSize size = PrintlyTextSize.normal,
  }) {
    final List<int> bytes = <int>[];

    if (align != _align) {
      bytes.addAll(_alignBytes(align));
      _align = align;
    }

    final bool bold = style.isBold;
    if (bold != _bold) {
      bytes.addAll(
        bold ? const <int>[0x1B, 0x45, 0x01] : const <int>[0x1B, 0x45, 0x00],
      );
      _bold = bold;
    }

    final bool underline = style.isUnderline;
    if (underline != _underline) {
      bytes.addAll(
        underline
            ? const <int>[0x1B, 0x2D, 0x01]
            : const <int>[0x1B, 0x2D, 0x00],
      );
      _underline = underline;
    }

    final int h = size.heightMultiplier;
    final int w = size.widthMultiplier;
    if (h != _heightMultiplier || w != _widthMultiplier) {
      final int decSize = 16 * (w - 1) + (h - 1);
      bytes.addAll(<int>[0x1D, 0x21, decSize]);
      _heightMultiplier = h;
      _widthMultiplier = w;
    }

    // Cancel Kanji character mode (`FS .`). Preserved for byte-for-byte
    // compatibility with the pre-v1.0 frozen golden; scheduled for removal in
    // its dedicated deviation commit.
    bytes.addAll(const <int>[0x1C, 0x2E]);

    return bytes;
  }

  /// Emits a single line of pre-encoded [encodedBytes] with the given style
  /// parameters, preceded by `ESC $ 0 0` (absolute print position 0) and
  /// terminated by a single line feed (`0x0A`).
  List<int> text(
    Uint8List encodedBytes, {
    PrintlyTextAlign align = PrintlyTextAlign.left,
    PrintlyTextStyle style = PrintlyTextStyle.normal,
    PrintlyTextSize size = PrintlyTextSize.normal,
  }) {
    return <int>[
      // ESC $ 0 0 — set absolute horizontal print position to column 0.
      0x1B, 0x24, 0x00, 0x00,
      ...setStyles(align: align, style: style, size: size),
      ...encodedBytes,
      0x0A,
    ];
  }

  /// Emits `ESC d n` (`0x1B 0x64 n`) to print the line buffer and feed [lines]
  /// blank lines (`1..255`).
  ///
  /// Throws [RangeError] if [lines] is outside `1..255` so out-of-range values
  /// never wrap modulo 256 in release builds.
  List<int> feed(int lines) {
    RangeError.checkValueInInterval(lines, 1, 255, 'lines');
    return <int>[0x1B, 0x64, lines];
  }

  /// Emits 5 line feeds (`0x0A`) followed by `GS V m` (`0x1D 0x56 m`, where
  /// `m` is `'0'` for [PrintlyCutMode.full] and `'1'` for
  /// [PrintlyCutMode.partial]).
  List<int> cut({PrintlyCutMode mode = PrintlyCutMode.full}) {
    return switch (mode) {
      PrintlyCutMode.full => const <int>[
        0x0A,
        0x0A,
        0x0A,
        0x0A,
        0x0A,
        0x1D,
        0x56,
        0x30,
      ],
      PrintlyCutMode.partial => const <int>[
        0x0A,
        0x0A,
        0x0A,
        0x0A,
        0x0A,
        0x1D,
        0x56,
        0x31,
      ],
    };
  }

  /// Validates [data] against [type] and emits the complete 1-D barcode
  /// sequence: alignment via [setStyles], HRI placement (`GS H`), module width
  /// (`GS w`), bar height (`GS h`), and symbol print (`GS k`).
  ///
  /// Symbologies [PrintlyBarcodeType.upcA] through [PrintlyBarcodeType.codabar]
  /// use `GS k` **Function A** (`m` = 0..6, NUL-terminated payload);
  /// [PrintlyBarcodeType.code128] uses **Function B** (`m` = 73, single-byte
  /// length prefix followed by the `{A`/`{B`/`{C`-prefixed payload).
  ///
  /// Throws [RangeError] if [height] (`1..255`) or [width] (`2..6`) is out of
  /// bounds, and [ArgumentError] if [data] violates the length or character-set
  /// rules of [type].
  List<int> barcode(
    String data, {
    required PrintlyBarcodeType type,
    required int height,
    required int width,
    required PrintlyHriPosition hriPosition,
    required PrintlyTextAlign align,
  }) {
    RangeError.checkValueInInterval(height, 1, 255, 'height');
    RangeError.checkValueInInterval(width, 2, 6, 'width');
    _validateBarcodePayload(type, data);

    final int m = _barcodeCommandSelector(type);
    final List<int> payloadBytes = data.codeUnits;

    return <int>[
      ...setStyles(align: align),
      0x1D,
      0x48,
      _hriPositionByte(hriPosition),
      0x1D,
      0x77,
      width,
      0x1D,
      0x68,
      height,
      0x1D,
      0x6B,
      m,
      if (m <= 6) ...<int>[...payloadBytes, 0x00] else ...<int>[
        payloadBytes.length,
        ...payloadBytes,
      ],
    ];
  }

  /// Emits the complete QR Code command sequence (`GS ( k` functions
  /// 167/169/180/181) preceded by alignment via [setStyles].
  ///
  /// Unlike `esc_pos_utils_plus`, which hardcoded `pH = 0` on function 180 and
  /// corrupted payloads over 252 bytes, this computes the two-byte little-endian
  /// store length (`pL`, `pH`) across the full `1..2953` byte-mode range.
  ///
  /// Throws [RangeError] if [moduleSize] is outside `1..16`, and
  /// [ArgumentError] if [payload] is empty or exceeds [maxQrBytes].
  List<int> qr(
    Uint8List payload, {
    required int moduleSize,
    required PrintlyQrErrorLevel errorLevel,
    required PrintlyTextAlign align,
  }) {
    RangeError.checkValueInInterval(moduleSize, 1, 16, 'moduleSize');
    if (payload.isEmpty || payload.length > maxQrBytes) {
      throw ArgumentError(
        'QR payload must be 1..$maxQrBytes bytes (got ${payload.length}).',
      );
    }
    final int storeLen = payload.length + 3;
    return <int>[
      ...setStyles(align: align),
      // Function 167: module size.
      ..._qrHeader, 0x03, 0x00, 0x31, 0x43, moduleSize,
      // Function 169: error correction level.
      ..._qrHeader, 0x03, 0x00, 0x31, 0x45, _qrErrorLevelByte(errorLevel),
      // Function 180: store data (pL/pH little-endian, len = data + 3).
      ..._qrHeader, storeLen & 0xFF, (storeLen >> 8) & 0xFF, 0x31, 0x50, 0x30,
      ...payload,
      // Function 181: print the stored symbol.
      ..._qrHeader, 0x03, 0x00, 0x31, 0x51, 0x30,
    ];
  }

  static List<int> _alignBytes(PrintlyTextAlign align) => switch (align) {
    PrintlyTextAlign.left => const <int>[0x1B, 0x61, 0x30],
    PrintlyTextAlign.center => const <int>[0x1B, 0x61, 0x31],
    PrintlyTextAlign.right => const <int>[0x1B, 0x61, 0x32],
  };

  static int _hriPositionByte(PrintlyHriPosition position) =>
      switch (position) {
        PrintlyHriPosition.none => 0x00,
        PrintlyHriPosition.above => 0x01,
        PrintlyHriPosition.below => 0x02,
        PrintlyHriPosition.both => 0x03,
      };

  static int _qrErrorLevelByte(PrintlyQrErrorLevel level) => switch (level) {
    PrintlyQrErrorLevel.low => 48,
    PrintlyQrErrorLevel.medium => 49,
    PrintlyQrErrorLevel.quartile => 50,
    PrintlyQrErrorLevel.high => 51,
  };

  static int _barcodeCommandSelector(PrintlyBarcodeType type) => switch (type) {
    PrintlyBarcodeType.upcA => 0,
    PrintlyBarcodeType.ean13 => 2,
    PrintlyBarcodeType.ean8 => 3,
    PrintlyBarcodeType.code39 => 4,
    PrintlyBarcodeType.itf => 5,
    PrintlyBarcodeType.codabar => 6,
    PrintlyBarcodeType.code128 => 73,
  };

  static void _validateBarcodePayload(PrintlyBarcodeType type, String data) {
    final int k = data.length;
    final bool valid = switch (type) {
      PrintlyBarcodeType.upcA => (k == 11 || k == 12) && _isAllDigits(data),
      PrintlyBarcodeType.ean13 => (k == 12 || k == 13) && _isAllDigits(data),
      PrintlyBarcodeType.ean8 => (k == 7 || k == 8) && _isAllDigits(data),
      PrintlyBarcodeType.code39 => k >= 1 && _isValidCode39(data),
      PrintlyBarcodeType.itf => k >= 2 && k.isEven && _isAllDigits(data),
      PrintlyBarcodeType.codabar => _isValidCodabar(data),
      PrintlyBarcodeType.code128 => _isValidCode128WirePayload(data),
    };
    if (!valid) {
      throw ArgumentError('Invalid ${type.name} barcode payload: "$data"');
    }
  }

  static bool _isAllDigits(String s) {
    for (int i = 0; i < s.length; i++) {
      final int c = s.codeUnitAt(i);
      if (c < 0x30 || c > 0x39) return false;
    }
    return true;
  }

  static bool _isValidCode39(String s) {
    for (int i = 0; i < s.length; i++) {
      final int c = s.codeUnitAt(i);
      final bool ok =
          (c >= 0x30 && c <= 0x39) || // 0-9
          (c >= 0x41 && c <= 0x5A) || // A-Z
          c == 0x20 || // space
          c == 0x24 || // $
          c == 0x25 || // %
          c == 0x2A || // *
          c == 0x2B || // +
          c == 0x2D || // -
          c == 0x2E || // .
          c == 0x2F; // /
      if (!ok) return false;
    }
    return true;
  }

  /// Validates an ESC/POS `GS k 6` (CODABAR / NW-7) payload:
  /// - Length ≥ 3 (start char + at least 1 data char + stop char).
  /// - Start and stop characters must both be `A–D` (`0x41..0x44`) or both be
  ///   `a–d` (`0x61..0x64`).
  /// - Interior characters (`1..length-2`) must be digits (`0–9`) or one of
  ///   `$ + - . / :` — start/stop letters are forbidden inside the body.
  static bool _isValidCodabar(String s) {
    if (s.length < 3) return false;
    final int first = s.codeUnitAt(0);
    final int last = s.codeUnitAt(s.length - 1);
    final bool upperFraming =
        first >= 0x41 && first <= 0x44 && last >= 0x41 && last <= 0x44;
    final bool lowerFraming =
        first >= 0x61 && first <= 0x64 && last >= 0x61 && last <= 0x64;
    if (!upperFraming && !lowerFraming) {
      return false;
    }
    for (int i = 1; i < s.length - 1; i++) {
      final int c = s.codeUnitAt(i);
      final bool ok =
          (c >= 0x30 && c <= 0x39) || // 0-9
          c == 0x24 || // $
          c == 0x2B || // +
          c == 0x2D || // -
          c == 0x2E || // .
          c == 0x2F || // /
          c == 0x3A; // :
      if (!ok) return false;
    }
    return true;
  }

  /// Validates an ESC/POS `GS k 73` (CODE128 Function B) wire payload:
  /// - Total wire length `3..255` bytes (2-byte `{A`/`{B`/`{C` selector + at
  ///   least 1 payload byte).
  /// - Must start with `{A`, `{B`, or `{C`.
  /// - Every byte must be 7-bit ASCII (`0x00..0x7F`).
  static bool _isValidCode128WirePayload(String s) {
    if (s.length < 3 || s.length > 255) return false;
    if (s.codeUnitAt(0) != 0x7B) return false; // '{'
    final int selector = s.codeUnitAt(1);
    if (selector != 0x41 && selector != 0x42 && selector != 0x43) {
      return false; // 'A', 'B', 'C'
    }
    for (int i = 2; i < s.length; i++) {
      if (s.codeUnitAt(i) > 0x7F) return false;
    }
    return true;
  }
}

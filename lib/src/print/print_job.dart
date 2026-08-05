import 'dart:convert' show latin1;
import 'dart:typed_data';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart' show GlobalKey;

import '../raster/printly_bitmap.dart';
import '../raster/printly_dithering.dart';
import '../raster/printly_raster.dart';
import '../raster/raster_encoder.dart';
import 'print_config.dart';
import 'printly_barcode_type.dart';
import 'printly_charset.dart';
import 'printly_cut_mode.dart';
import 'printly_hri_position.dart';
import 'printly_paper_width.dart';
import 'printly_qr_error_level.dart';
import 'printly_text_align.dart';
import 'printly_text_size.dart';
import 'printly_text_style.dart';
import 'printly_unmappable.dart';
import 'qr_sizing.dart';
import 'turkish_code_page.dart';

/// A fluent builder for an ESC/POS receipt.
///
/// Obtain one with `Printly.instance.newJob(...)` (or [PrintJob.create]), chain
/// commands, then hand it to `Printly.instance.print(device, job)` (which calls
/// [build]). Each command returns the same job so calls can be chained with
/// `..`:
///
/// ```dart
/// final job = await Printly.instance.newJob(paperWidth: PrintlyPaperWidth.mm58);
/// job
///   ..text('MAĞAZA', align: PrintlyTextAlign.center, style: PrintlyTextStyle.bold,
///           charset: PrintlyCharset.turkish)
///   ..divider()
///   ..text('Teşekkürler', charset: PrintlyCharset.turkish)
///   ..qr('https://example.com')
///   ..feed(2)
///   ..cut();
/// await Printly.instance.print(device, job);
/// ```
///
/// printly reuses the `esc_pos_utils_plus` [Generator] for command framing but
/// encodes Turkish text itself (via [TurkishCodePage]) because the library only
/// encodes through `latin1`, which cannot represent the Turkish letters.
class PrintJob {
  PrintJob._(this._generator, this._config) {
    // Start every job with ESC @ so the printer is in a known state.
    _bytes.addAll(_generator.reset());
  }

  /// Test-only seam that builds a job around a pre-constructed [generator],
  /// avoiding the asynchronous capability-profile load. Production code should
  /// use [create] / `Printly.instance.newJob(...)`.
  @visibleForTesting
  factory PrintJob.fromGenerator({
    required Generator generator,
    PrintConfig config = const PrintConfig(),
  }) => PrintJob._(generator, config);

  /// Creates a job for the given paper width, loading (and caching) the ESC/POS
  /// capability profile on first use. When [config] is supplied its
  /// [PrintConfig.paperWidth] takes precedence over the [paperWidth] argument.
  static Future<PrintJob> create({
    PrintlyPaperWidth paperWidth = PrintlyPaperWidth.mm58,
    PrintConfig? config,
  }) async {
    final PrintConfig cfg = config ?? PrintConfig(paperWidth: paperWidth);
    final Future<CapabilityProfile> future = _profileFuture ??=
        CapabilityProfile.load();
    final CapabilityProfile profile;
    try {
      profile = await future;
    } catch (_) {
      // Evict the failed future so a later call retries the asset load
      // instead of rethrowing the same stale error forever (e.g. after a
      // too-early first call before the binding was initialised).
      if (identical(_profileFuture, future)) {
        _profileFuture = null;
      }
      rethrow;
    }
    return PrintJob._(Generator(_toPaperSize(cfg.paperWidth), profile), cfg);
  }

  static Future<CapabilityProfile>? _profileFuture;

  // The ESC d (feed n lines) operand is a single byte, and feeding 0 lines is
  // a no-op, so feed counts are clamped into this range everywhere.
  static const int _minFeedLines = 1;
  static const int _maxFeedLines = 255;

  // Barcode height (GS h) operand bounds.
  static const int _minBarcodeHeight = 1;
  static const int _maxBarcodeHeight = 255;

  // Barcode module width (GS w) operand bounds per the ESC/POS spec, and the
  // default emitted when the caller does not choose one. Always emitting the
  // width keeps every barcode self-contained (GS w persists until ESC @).
  static const int _minBarcodeWidth = 2;
  static const int _maxBarcodeWidth = 6;
  static const int _defaultBarcodeWidth = 3;

  // GS ( k — the QR command header shared by all QR functions.
  static const List<int> _qrHeader = <int>[0x1D, 0x28, 0x6B];

  // Absolute QR byte-mode capacity (version 40, error level L). Anything
  // larger cannot be encoded by any printer.
  static const int _maxQrBytes = 2953;

  // Sanitization targets per symbology. CODE128 subset B covers printable
  // ASCII (0x20-0x7E; 0x7F DEL is in the code set but not printable — a
  // replacement no scanner app can display is useless, so it is excluded).
  // CODE39 has its own narrow set. Numeric symbologies (EAN/UPC/ITF) and
  // CODABAR are deliberately absent: substituting characters in a
  // check-digit payload would print a scannable-but-wrong code.
  static final Set<int> _code128Charset = <int>{
    for (int c = 0x20; c <= 0x7E; c++) c,
  };
  static final Set<int> _code39Charset = <int>{
    for (int c = 0x30; c <= 0x39; c++) c, // 0-9
    for (int c = 0x41; c <= 0x5A; c++) c, // A-Z
    0x2D, 0x2E, 0x24, 0x2F, 0x2B, 0x25, 0x20, // - . $ / + % space
  };

  final Generator _generator;
  final PrintConfig _config;
  final List<int> _bytes = <int>[];
  bool _cutEmitted = false;

  /// The configuration this job was created with.
  PrintConfig get config => _config;

  /// Target paper width (from [config]).
  PrintlyPaperWidth get paperWidth => _config.paperWidth;

  /// Appends a line of [content].
  ///
  /// [charset] overrides [PrintConfig.charset] for this line only. When the
  /// charset declares an `ESC t` page it is selected immediately before the
  /// text, so each line is self-contained and the printer never carries a
  /// stale code page between lines.
  PrintJob text(
    String content, {
    PrintlyTextAlign align = PrintlyTextAlign.left,
    PrintlyTextStyle style = PrintlyTextStyle.normal,
    PrintlyTextSize size = PrintlyTextSize.normal,
    PrintlyCharset? charset,
  }) {
    final PrintlyCharset cs = charset ?? _config.charset;
    final int? escT = cs.escTCode;
    if (escT != null) {
      _bytes.addAll(<int>[0x1B, 0x74, escT]);
    }
    final Uint8List encoded = TurkishCodePage.encode(content, charset: cs);
    final PosStyles styles = PosStyles(
      align: _toPosAlign(align),
      bold: style.isBold,
      underline: style.isUnderline,
      height: _toPosTextSize(size.heightMultiplier),
      width: _toPosTextSize(size.widthMultiplier),
    );
    _bytes.addAll(_generator.textEncoded(encoded, styles: styles));
    return this;
  }

  /// Feeds [lines] blank lines (clamped to `1..255`).
  PrintJob feed([int lines = 1]) {
    _bytes.addAll(_emitFeed(lines));
    return this;
  }

  /// Cuts the paper. Defaults to [PrintConfig.cutMode] when [mode] is omitted.
  ///
  /// Calling this suppresses the automatic [PrintConfig.cutAfterPrint] cut in
  /// [build], so a job never cuts twice.
  PrintJob cut({PrintlyCutMode? mode}) {
    _bytes.addAll(_generator.cut(mode: _toPosCutMode(mode ?? _config.cutMode)));
    _cutEmitted = true;
    return this;
  }

  /// Prints a full-width divider made of repeated [char] (first character
  /// only), sized to the paper's characters-per-line.
  PrintJob divider({String char = '-'}) {
    final String unit = char.isEmpty
        ? '-'
        : String.fromCharCode(char.runes.first);
    final String line = unit * _config.paperWidth.maxCharsPerLine;
    return text(line, charset: PrintlyCharset.latin);
  }

  /// Appends raw, pre-built ESC/POS [bytes] verbatim — an escape hatch for
  /// commands printly does not model.
  ///
  /// **Warning:** raw bytes that change styles, alignment or the code page
  /// (e.g. `ESC E`, `ESC a`, `GS !`, `ESC t`) are not tracked by the
  /// generator's style cache, so subsequent [text] calls may not emit the
  /// commands needed to reset them and can print with the leaked state.
  PrintJob raw(List<int> bytes) {
    _bytes.addAll(bytes);
    return this;
  }

  /// Appends a 1-D [type] barcode encoding [data].
  ///
  /// [height] is in dots and is clamped to `1..255`; [width] is the module
  /// width in dots, clamped to the spec range `2..6` (default 3) and emitted
  /// on every barcode so one barcode's width never leaks into the next.
  /// [showText] toggles the human-readable digits, positioned by
  /// [textPosition]. CODE128 payloads are automatically prefixed with the
  /// `{B` code set and literal `{` characters are escaped; a caller-supplied
  /// `{A`/`{B`/`{C` selector is kept as-is (with the remainder escaped).
  ///
  /// [unmappable] chooses what happens to characters the symbology cannot
  /// encode. It only applies to [PrintlyBarcodeType.code128] (target:
  /// printable ASCII, unless [data] starts with an explicit `{A`/`{B`/`{C`
  /// code-set selector — that hands the caller manual control and the
  /// printable-ASCII gate is skipped) and [PrintlyBarcodeType.code39] (its
  /// narrow charset; lowercase is folded to uppercase first). Numeric
  /// symbologies and CODABAR always validate strictly — substituting
  /// characters in a check-digit payload would print a scannable-but-wrong
  /// code.
  /// [replacement] defaults per symbology (`?` for CODE128, `-` for CODE39)
  /// and must itself be encodable, otherwise [ArgumentError].
  /// [replacement] has no effect under [PrintlyUnmappable.throwError].
  /// Throws [ArgumentError] when the (sanitized) [data] is not valid for
  /// [type].
  PrintJob barcode(
    String data, {
    PrintlyBarcodeType type = PrintlyBarcodeType.code128,
    int height = 60,
    int? width,
    bool showText = true,
    PrintlyHriPosition textPosition = PrintlyHriPosition.below,
    PrintlyTextAlign align = PrintlyTextAlign.center,
    PrintlyUnmappable unmappable = PrintlyUnmappable.throwError,
    int? replacement,
  }) {
    final String sanitized = _sanitizeBarcode(
      data,
      type,
      unmappable,
      replacement,
    );
    final Barcode bc = _buildBarcode(type, sanitized);
    final BarcodeText hri = showText
        ? _toBarcodeText(textPosition)
        : BarcodeText.none;
    _bytes.addAll(
      _generator.barcode(
        bc,
        height: height.clamp(_minBarcodeHeight, _maxBarcodeHeight),
        width: (width ?? _defaultBarcodeWidth).clamp(
          _minBarcodeWidth,
          _maxBarcodeWidth,
        ),
        textPos: hri,
        align: _toPosAlign(align),
      ),
    );
    return this;
  }

  /// Appends a QR code encoding [data] with smart module sizing.
  ///
  /// The module dot size is derived from the payload length, [errorLevel] and
  /// the paper width so the symbol fills the line without overflowing. Pass
  /// [maxModuleSize] to cap the physical size.
  ///
  /// [data] must be representable in Latin-1 (the encoding the printer stores
  /// QR symbols in). What happens to runes outside Latin-1 — including the
  /// Turkish letters `ş ı ğ İ` — is chosen by [unmappable]: the default
  /// [PrintlyUnmappable.throwError] throws [ArgumentError] so silent data
  /// loss in a scannable code stays opt-in;
  /// [PrintlyUnmappable.transliterate] converts readable equivalents via
  /// [TurkishCodePage.toLatin1] and substitutes the rest with [replacement];
  /// [PrintlyUnmappable.replace] substitutes everything above `0xFF`.
  /// [replacement] has no effect under [PrintlyUnmappable.throwError].
  /// Payloads longer than 2953 bytes (the QR byte-mode maximum, measured
  /// after sanitization — `…` expands to `...`) always throw.
  PrintJob qr(
    String data, {
    int? maxModuleSize,
    PrintlyQrErrorLevel errorLevel = PrintlyQrErrorLevel.medium,
    PrintlyTextAlign align = PrintlyTextAlign.center,
    PrintlyUnmappable unmappable = PrintlyUnmappable.throwError,
    int replacement = TurkishCodePage.unmappable,
  }) {
    final String sanitized = switch (unmappable) {
      PrintlyUnmappable.throwError => data,
      PrintlyUnmappable.replace => TurkishCodePage.toLatin1(
        data,
        transliterate: false,
        replacement: replacement,
      ),
      PrintlyUnmappable.transliterate => TurkishCodePage.toLatin1(
        data,
        replacement: replacement,
      ),
    };
    if (sanitized.runes.any((int rune) => rune > 0xFF)) {
      throw ArgumentError(
        'Invalid QR payload: contains characters outside Latin-1 (e.g. the '
        'Turkish letters ş/ı/ğ/İ). QR data must be Latin-1; pass '
        'unmappable: PrintlyUnmappable.transliterate to sanitize instead. '
        'Got: "$data"',
      );
    }
    final Uint8List payload = Uint8List.fromList(latin1.encode(sanitized));
    if (payload.length > _maxQrBytes) {
      throw ArgumentError(
        'QR payload is ${payload.length} bytes; the QR byte-mode maximum is '
        '$_maxQrBytes.',
      );
    }
    final int moduleSize = QrSizing.moduleSize(
      data: sanitized,
      errorLevel: errorLevel,
      paperDots: _config.paperWidth.dots,
      maxModuleSize: maxModuleSize,
    );
    _bytes.addAll(_emitQr(payload, moduleSize, errorLevel, align));
    return this;
  }

  /// Emits the QR function sequence (GS ( k 167/169/180/181) directly.
  ///
  /// The wrapped library's store command hardcodes `pH = 0`, so any payload
  /// over 252 bytes overflows `pL` and prints garbage; this emits the same
  /// function set with correct two-byte length math. Alignment goes through
  /// [Generator.setStyles] so the generator's style cache stays coherent for
  /// subsequent [text] calls.
  List<int> _emitQr(
    Uint8List payload,
    int moduleSize,
    PrintlyQrErrorLevel errorLevel,
    PrintlyTextAlign align,
  ) {
    final int storeLen = payload.length + 3;
    return <int>[
      ..._generator.setStyles(
        const PosStyles().copyWith(align: _toPosAlign(align)),
      ),
      // Function 167: module size.
      ..._qrHeader, 0x03, 0x00, 0x31, 0x43, moduleSize,
      // Function 169: error correction level.
      ..._qrHeader, 0x03, 0x00, 0x31, 0x45, _toQrCorrection(errorLevel).value,
      // Function 180: store data (pL/pH little-endian, len = data + 3).
      ..._qrHeader, storeLen & 0xFF, (storeLen >> 8) & 0xFF, 0x31, 0x50, 0x30,
      ...payload,
      // Function 181: print the stored symbol.
      ..._qrHeader, 0x03, 0x00, 0x31, 0x51, 0x30,
    ];
  }

  /// Appends an already-rendered [PrintlyBitmap] as a raster image.
  ///
  /// Synchronous, so it chains like every other command. Rendering is the
  /// asynchronous half and happens first, through [PrintlyRaster]:
  ///
  /// ```dart
  /// final header = await PrintlyRaster.text('MAĞAZA', width: 384, bold: true);
  /// job..bitmap(header)..text('...')..cut();
  /// ```
  ///
  /// Splitting it this way is not only about keeping the cascade. A bitmap is
  /// immutable, so a logo rendered once at startup can be stamped onto every
  /// receipt for the rest of the session at no further cost.
  ///
  /// [align] positions the block on the paper, which only shows when the bitmap
  /// is narrower than the paper — full-width images look the same at every
  /// setting. It is applied through the generator's style cache rather than as
  /// raw bytes; writing `ESC a` directly would leave that cache believing the
  /// alignment never changed, and the next [text] call would then skip emitting
  /// its own and print misaligned.
  ///
  /// An empty bitmap emits nothing.
  PrintJob bitmap(
    PrintlyBitmap bitmap, {
    PrintlyTextAlign align = PrintlyTextAlign.center,
  }) {
    if (bitmap.isEmpty) return this;
    _bytes
      ..addAll(
        _generator.setStyles(
          const PosStyles().copyWith(align: _toPosAlign(align)),
        ),
      )
      ..addAll(
        RasterEncoder.emit(bitmap, bandHeight: _config.rasterBandHeight),
      );
    return this;
  }

  /// Renders [content] to dots and appends it — Turkish text that does not
  /// depend on the printer's code page.
  ///
  /// The reason to prefer this over [text] is narrow but decisive: printers in
  /// the PTP-II class ignore `ESC t` entirely and stay on CP437 forever, so
  /// `ğ`, `ş` and `İ` are unreachable through the character-set path. Drawing
  /// the glyphs sidesteps the printer's font altogether. On printers that do
  /// honour code pages, [text] remains the cheaper choice — far fewer bytes.
  ///
  /// [width] defaults to the full paper width, so [align] positions the text
  /// within the line rather than moving a block around.
  ///
  /// **Must be awaited.** The return type makes `job..textRaster(a)
  /// ..textRaster(b)` a compile error rather than a source of scrambled
  /// receipts; for a long job, prefer rendering up front and chaining
  /// [bitmap] calls.
  Future<PrintJob> textRaster(
    String content, {
    int? width,
    double fontSize = PrintlyRaster.defaultFontSize,
    PrintlyTextAlign align = PrintlyTextAlign.left,
    bool bold = false,
    String? fontFamily,
    PrintlyDithering dithering = PrintlyDithering.threshold,
    int threshold = PrintlyRaster.defaultTextThreshold,
  }) async {
    final PrintlyBitmap rendered = await PrintlyRaster.text(
      content,
      width: width ?? _config.paperWidth.dots,
      fontSize: fontSize,
      align: align,
      bold: bold,
      fontFamily: fontFamily,
      dithering: dithering,
      threshold: threshold,
    );
    // The bitmap already spans the requested width and carries the alignment
    // inside it, so the block itself sits flush left.
    return bitmap(rendered, align: PrintlyTextAlign.left);
  }

  /// Decodes [encoded] (PNG, JPEG, WebP, …) and appends it as dots.
  ///
  /// [width] is a ceiling that defaults to the paper width: wider images are
  /// scaled down, narrower ones keep their size and are positioned by [align].
  ///
  /// Watch the ink coverage, not just the size. A large area of solid black
  /// draws more current than a cheap 5 V printer can sustain, and it can shut
  /// down mid-receipt without reporting anything the app could catch. Line art
  /// prints far more reliably than photographs.
  ///
  /// **Must be awaited** — see [textRaster].
  Future<PrintJob> image(
    Uint8List encoded, {
    int? width,
    PrintlyTextAlign align = PrintlyTextAlign.center,
    PrintlyDithering dithering = PrintlyDithering.floydSteinberg,
    int threshold = PrintlyBitmap.defaultThreshold,
  }) async {
    final PrintlyBitmap rendered = await PrintlyRaster.image(
      encoded,
      width: width ?? _config.paperWidth.dots,
      dithering: dithering,
      threshold: threshold,
    );
    return bitmap(rendered, align: align);
  }

  /// Captures the `RepaintBoundary` carrying [boundaryKey] and appends it.
  ///
  /// The boundary must be mounted and painted — keep it on screen, which is no
  /// hardship since a visible receipt preview is useful in its own right.
  /// `Offstage` and `Opacity(0)` subtrees are never painted and are rejected.
  ///
  /// Takes a key rather than a widget because Flutter offers no supported way
  /// to render a detached widget tree; an API that accepted a `Widget` would be
  /// promising something it cannot do.
  ///
  /// **Must be awaited** — see [textRaster].
  Future<PrintJob> widget(
    GlobalKey boundaryKey, {
    int? width,
    PrintlyTextAlign align = PrintlyTextAlign.center,
    PrintlyDithering dithering = PrintlyDithering.threshold,
    int threshold = PrintlyRaster.defaultTextThreshold,
  }) async {
    final PrintlyBitmap rendered = await PrintlyRaster.widgetKey(
      boundaryKey,
      width: width ?? _config.paperWidth.dots,
      dithering: dithering,
      threshold: threshold,
    );
    return bitmap(rendered, align: align);
  }

  /// Serialises the job to printer-ready bytes.
  ///
  /// Applies the [PrintConfig] finalisers — [PrintConfig.feedLines] then a cut
  /// when [PrintConfig.cutAfterPrint] is set and no explicit [cut] was already
  /// chained — without mutating the builder, so [build] is safe to call more
  /// than once.
  Uint8List build() {
    final List<int> out = <int>[..._bytes];
    if (_config.feedLines > 0) {
      out.addAll(_emitFeed(_config.feedLines));
    }
    if (_config.cutAfterPrint && !_cutEmitted) {
      out.addAll(_generator.cut(mode: _toPosCutMode(_config.cutMode)));
    }
    return Uint8List.fromList(out);
  }

  List<int> _emitFeed(int lines) =>
      _generator.feed(lines.clamp(_minFeedLines, _maxFeedLines));

  Barcode _buildBarcode(PrintlyBarcodeType type, String data) {
    try {
      return switch (type) {
        PrintlyBarcodeType.ean13 => Barcode.ean13(data.split('')),
        PrintlyBarcodeType.ean8 => Barcode.ean8(data.split('')),
        PrintlyBarcodeType.upcA => Barcode.upcA(data.split('')),
        PrintlyBarcodeType.code39 => Barcode.code39(data.split('')),
        PrintlyBarcodeType.itf => Barcode.itf(data.split('')),
        PrintlyBarcodeType.codabar => Barcode.codabar(data.split('')),
        PrintlyBarcodeType.code128 => Barcode.code128(
          _code128Payload(data).split(''),
        ),
      };
    } on Exception catch (error) {
      throw ArgumentError('Invalid ${type.name} barcode payload: $error');
    }
  }

  /// Applies the [PrintlyUnmappable] policy for the symbologies where a
  /// substitution cannot corrupt the payload semantics (CODE128, CODE39).
  static String _sanitizeBarcode(
    String data,
    PrintlyBarcodeType type,
    PrintlyUnmappable unmappable,
    int? replacement,
  ) {
    final Set<int>? allowed = switch (type) {
      PrintlyBarcodeType.code128 => _code128Charset,
      PrintlyBarcodeType.code39 => _code39Charset,
      _ => null,
    };

    if (unmappable == PrintlyUnmappable.throwError) {
      // The wrapped library validates CODE39 and the numeric symbologies
      // itself, but Barcode.code128 only checks length — a non-encodable
      // rune would silently print a corrupt symbol. Enforce the documented
      // ArgumentError contract here, against the same charset the
      // sanitizer targets.
      //
      // A caller-supplied {A/{B/{C selector takes manual control of the
      // code set (code set A legitimately encodes 0x00-0x1F), so the
      // printable-ASCII contract below only guards the auto-{B path.
      final bool hasSelector =
          data.length >= 2 &&
          data[0] == '{' &&
          (data[1] == 'A' || data[1] == 'B' || data[1] == 'C');
      if (type == PrintlyBarcodeType.code128 &&
          !hasSelector &&
          data.runes.any((int rune) => !_code128Charset.contains(rune))) {
        throw ArgumentError(
          'Invalid code128 barcode payload: contains characters outside '
          'printable ASCII. Pass unmappable: PrintlyUnmappable.transliterate '
          'to sanitize instead. Got: "$data"',
        );
      }
      return data;
    }

    if (allowed == null) return data;
    final int fallback =
        replacement ??
        (type == PrintlyBarcodeType.code39 ? 0x2D : TurkishCodePage.unmappable);
    if (!allowed.contains(fallback)) {
      throw ArgumentError.value(
        fallback,
        'replacement',
        'not encodable in ${type.name}',
      );
    }
    String result = TurkishCodePage.toLatin1(
      data,
      transliterate: unmappable == PrintlyUnmappable.transliterate,
      replacement: fallback,
    );
    if (type == PrintlyBarcodeType.code39) {
      result = result.toUpperCase();
    }
    final StringBuffer out = StringBuffer();
    for (final int rune in result.runes) {
      out.writeCharCode(allowed.contains(rune) ? rune : fallback);
    }
    return out.toString();
  }

  /// Builds the CODE128 wire payload: in code set B a literal `{` must be
  /// doubled (`{{`), otherwise the printer reads it as a mid-data code-set
  /// switch. A leading `{A`/`{B`/`{C` is honoured as the caller's code-set
  /// selector; everything after it is escaped.
  static String _code128Payload(String data) {
    final bool hasSelector =
        data.length >= 2 &&
        data[0] == '{' &&
        (data[1] == 'A' || data[1] == 'B' || data[1] == 'C');
    if (hasSelector) {
      final String rest = data.substring(2);
      return data.substring(0, 2) + rest.replaceAll('{', '{{');
    }
    return '{B${data.replaceAll('{', '{{')}';
  }

  static PaperSize _toPaperSize(PrintlyPaperWidth width) => switch (width) {
    PrintlyPaperWidth.mm58 => PaperSize.mm58,
    PrintlyPaperWidth.mm80 => PaperSize.mm80,
  };

  static PosAlign _toPosAlign(PrintlyTextAlign align) => switch (align) {
    PrintlyTextAlign.left => PosAlign.left,
    PrintlyTextAlign.center => PosAlign.center,
    PrintlyTextAlign.right => PosAlign.right,
  };

  static PosTextSize _toPosTextSize(int multiplier) =>
      multiplier >= 2 ? PosTextSize.size2 : PosTextSize.size1;

  static PosCutMode _toPosCutMode(PrintlyCutMode mode) => switch (mode) {
    PrintlyCutMode.full => PosCutMode.full,
    PrintlyCutMode.partial => PosCutMode.partial,
  };

  static BarcodeText _toBarcodeText(PrintlyHriPosition position) =>
      switch (position) {
        PrintlyHriPosition.none => BarcodeText.none,
        PrintlyHriPosition.above => BarcodeText.above,
        PrintlyHriPosition.below => BarcodeText.below,
        PrintlyHriPosition.both => BarcodeText.both,
      };

  static QRCorrection _toQrCorrection(PrintlyQrErrorLevel level) =>
      switch (level) {
        PrintlyQrErrorLevel.low => QRCorrection.L,
        PrintlyQrErrorLevel.medium => QRCorrection.M,
        PrintlyQrErrorLevel.quartile => QRCorrection.Q,
        PrintlyQrErrorLevel.high => QRCorrection.H,
      };
}

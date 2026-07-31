import '../raster/raster_encoder.dart';
import 'printly_charset.dart';
import 'printly_cut_mode.dart';
import 'printly_paper_width.dart';

/// Job-wide defaults applied while building and finalising a [PrintJob].
///
/// A config is immutable; use [copyWith] to derive a variant.
///
/// Dithering and threshold are deliberately **not** here. The right default
/// differs by content — sharp thresholding suits text, error diffusion suits
/// photographs — so a single job-wide value would be wrong for one of them.
/// They are per-call arguments on `PrintlyRaster` instead.
class PrintConfig {
  /// Creates a print configuration. All fields have receipt-friendly defaults.
  const PrintConfig({
    this.paperWidth = PrintlyPaperWidth.mm58,
    this.charset = PrintlyCharset.latin,
    this.feedLines = 0,
    this.cutAfterPrint = false,
    this.cutMode = PrintlyCutMode.full,
    this.rasterBandHeight = RasterEncoder.defaultBandHeight,
  }) : assert(feedLines >= 0, 'feedLines must be non-negative'),
       assert(
         rasterBandHeight >= 1 &&
             rasterBandHeight <= RasterEncoder.maxBandHeight,
         'rasterBandHeight must be 1..255 rows',
       );

  /// Target paper width — drives line length and smart QR/barcode sizing.
  final PrintlyPaperWidth paperWidth;

  /// Default character set for [PrintJob.text] calls that do not override it.
  final PrintlyCharset charset;

  /// Number of blank lines fed after the body when [PrintJob.build] finalises
  /// the job. `0` disables the automatic feed.
  final int feedLines;

  /// Whether [PrintJob.build] appends a paper cut after the body (and the
  /// [feedLines]).
  final bool cutAfterPrint;

  /// Cut style used when [cutAfterPrint] is true.
  final PrintlyCutMode cutMode;

  /// Rows per `GS v 0` block when [PrintJob.bitmap] emits a raster image.
  ///
  /// A tall image is split into bands so no single block has to fit the
  /// printer's buffer whole. The default keeps each band around 3 KB at 58 mm
  /// and, being under 256, keeps the command's high height byte at zero —
  /// firmware that ignores that byte is a known hazard. Raise it only against a
  /// printer you have measured; the header overhead it saves is under 0.3%.
  final int rasterBandHeight;

  /// Returns a copy with the given fields replaced.
  PrintConfig copyWith({
    PrintlyPaperWidth? paperWidth,
    PrintlyCharset? charset,
    int? feedLines,
    bool? cutAfterPrint,
    PrintlyCutMode? cutMode,
    int? rasterBandHeight,
  }) {
    return PrintConfig(
      paperWidth: paperWidth ?? this.paperWidth,
      charset: charset ?? this.charset,
      feedLines: feedLines ?? this.feedLines,
      cutAfterPrint: cutAfterPrint ?? this.cutAfterPrint,
      cutMode: cutMode ?? this.cutMode,
      rasterBandHeight: rasterBandHeight ?? this.rasterBandHeight,
    );
  }
}

import 'printly_charset.dart';
import 'printly_cut_mode.dart';
import 'printly_paper_width.dart';

/// Job-wide defaults applied while building and finalising a [PrintJob].
///
/// A config is immutable; use [copyWith] to derive a variant. Image-related
/// options (dithering, threshold, DPI) are intentionally absent until the
/// image/widget pipeline lands in Sprint 5.
class PrintConfig {
  /// Creates a print configuration. All fields have receipt-friendly defaults.
  const PrintConfig({
    this.paperWidth = PrintlyPaperWidth.mm58,
    this.charset = PrintlyCharset.latin,
    this.feedLines = 0,
    this.cutAfterPrint = false,
    this.cutMode = PrintlyCutMode.full,
  }) : assert(feedLines >= 0, 'feedLines must be non-negative');

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

  /// Returns a copy with the given fields replaced.
  PrintConfig copyWith({
    PrintlyPaperWidth? paperWidth,
    PrintlyCharset? charset,
    int? feedLines,
    bool? cutAfterPrint,
    PrintlyCutMode? cutMode,
  }) {
    return PrintConfig(
      paperWidth: paperWidth ?? this.paperWidth,
      charset: charset ?? this.charset,
      feedLines: feedLines ?? this.feedLines,
      cutAfterPrint: cutAfterPrint ?? this.cutAfterPrint,
      cutMode: cutMode ?? this.cutMode,
    );
  }
}

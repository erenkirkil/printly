/// Physical width of the thermal paper roll a job targets.
///
/// The dot width drives line length, divider width, and the smart QR/barcode
/// sizing maths. Values assume the common 203 dpi (8 dots/mm) print head, so
/// the printable area is 384 dots for 58 mm rolls and 576 dots for 80 mm.
enum PrintlyPaperWidth {
  /// 58 mm roll — 384 printable dots, 32 characters per line in Font A.
  mm58,

  /// 80 mm roll — 576 printable dots, 48 characters per line in Font A.
  mm80;

  /// Printable width in dots for the 203 dpi print head.
  int get dots => switch (this) {
    PrintlyPaperWidth.mm58 => 384,
    PrintlyPaperWidth.mm80 => 576,
  };

  /// Maximum monospaced characters per line in the default Font A (12 dots
  /// wide). Used by [PrintJob.divider] and line-fitting helpers.
  int get maxCharsPerLine => switch (this) {
    PrintlyPaperWidth.mm58 => 32,
    PrintlyPaperWidth.mm80 => 48,
  };
}

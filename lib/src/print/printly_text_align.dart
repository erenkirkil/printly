/// Horizontal alignment of a printed line.
///
/// Prefixed to avoid a name clash with `dart:ui`/Material's `TextAlign`, so
/// consumers never have to `hide` a framework type when importing printly.
enum PrintlyTextAlign {
  /// Align to the left edge of the paper (printer default).
  left,

  /// Centre within the printable width.
  center,

  /// Align to the right edge of the paper.
  right,
}

/// Emphasis applied to a printed line.
///
/// Prefixed to avoid a name clash with `dart:ui`/Material's `TextStyle`.
enum PrintlyTextStyle {
  /// No emphasis (printer default).
  normal,

  /// Bold / emphasised text (`ESC E 1`).
  bold,

  /// Underlined text (`ESC - 1`).
  underline,

  /// Both bold and underlined.
  boldUnderline;

  /// Whether this style enables bold emphasis.
  bool get isBold =>
      this == PrintlyTextStyle.bold || this == PrintlyTextStyle.boldUnderline;

  /// Whether this style enables underline.
  bool get isUnderline =>
      this == PrintlyTextStyle.underline ||
      this == PrintlyTextStyle.boldUnderline;
}

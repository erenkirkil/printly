/// Character magnification for a printed line (`GS ! n`).
///
/// Prefixed to avoid a name clash with any framework `TextSize` symbol and to
/// keep the printly public surface self-consistent.
enum PrintlyTextSize {
  /// Normal 1×1 character size (printer default).
  normal,

  /// Double width, normal height.
  doubleWidth,

  /// Normal width, double height.
  doubleHeight,

  /// Double width and double height.
  doubleWidthHeight;

  /// Horizontal magnification factor (1 or 2).
  int get widthMultiplier => switch (this) {
    PrintlyTextSize.normal => 1,
    PrintlyTextSize.doubleHeight => 1,
    PrintlyTextSize.doubleWidth => 2,
    PrintlyTextSize.doubleWidthHeight => 2,
  };

  /// Vertical magnification factor (1 or 2).
  int get heightMultiplier => switch (this) {
    PrintlyTextSize.normal => 1,
    PrintlyTextSize.doubleWidth => 1,
    PrintlyTextSize.doubleHeight => 2,
    PrintlyTextSize.doubleWidthHeight => 2,
  };
}

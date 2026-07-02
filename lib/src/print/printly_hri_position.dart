/// Placement of the Human-Readable Interpretation (HRI) digits printed
/// alongside a barcode (`GS H`).
enum PrintlyHriPosition {
  /// Do not print the HRI text (`GS H 0`).
  none,

  /// Print the HRI text above the barcode (`GS H 1`).
  above,

  /// Print the HRI text below the barcode (`GS H 2`).
  below,

  /// Print the HRI text both above and below (`GS H 3`).
  both,
}

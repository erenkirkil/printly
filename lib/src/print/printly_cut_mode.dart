/// Paper cut behaviour emitted at the end of a job (`GS V`).
enum PrintlyCutMode {
  /// Full cut — separates the receipt completely (`GS V 0`).
  full,

  /// Partial cut — leaves a small tab so the receipt stays attached
  /// (`GS V 1`).
  partial,
}

/// 1-D barcode symbologies supported by [PrintJob.barcode].
///
/// [ean13], [ean8], [upcA], [code39], [itf] and [codabar] are emitted with the
/// ESC/POS `GS k` **function A** selectors (`m` = 0–6, NUL-terminated data);
/// only [code128] uses **function B** (`m` = 73, length-prefixed data). The
/// Dart-side [PrintJob] validates the payload against the symbology before
/// emitting it.
enum PrintlyBarcodeType {
  /// EAN-13 / JAN-13 — 12 or 13 digits.
  ean13,

  /// EAN-8 / JAN-8 — 7 or 8 digits.
  ean8,

  /// UPC-A — 11 or 12 digits.
  upcA,

  /// CODE39 — digits, uppercase letters and a small symbol set.
  code39,

  /// CODE128 — full ASCII; requires a `{A`/`{B`/`{C` code-set prefix.
  code128,

  /// ITF (Interleaved 2 of 5) — an even number of digits.
  itf,

  /// CODABAR (NW-7) — digits with `A`–`D` start/stop characters.
  codabar,
}

/// Character encoding used when serialising text to printer bytes.
///
/// Thermal printers cannot render Turkish glyphs (`ğ ş ı İ ç ö ü` …) from the
/// default Latin code page, so [PrintlyCharset.turkish] (CP857) is the primary
/// Turkish option with [PrintlyCharset.windows1254] as a fallback for printers
/// whose firmware maps the Turkish page differently. See [TurkishCodePage] for
/// the byte-level mapping and [escTCode] for the `ESC t n` selector.
enum PrintlyCharset {
  /// CP437 — the printer power-on Latin default. Western European accents
  /// (`é ü ç ö ä à £ ° …`) are available, but the Turkish-specific letters
  /// `ğ Ğ ı İ ş Ş` are not and are substituted with `?`.
  latin,

  /// CP857 (IBM Turkish) — the most widely supported Turkish page.
  turkish,

  /// WPC1254 (Windows-1254 Turkish) — fallback for printers that prefer the
  /// Windows code page over CP857.
  windows1254,

  /// ISO-8859-9 (Latin-5). Shares its `0xA0–0xFF` range with Windows-1254, so
  /// it is selected with the same printer page.
  iso8859_9,

  /// UTF-8 — only for the minority of printers running in a UTF-8 capable
  /// mode. No `ESC t` page is emitted.
  utf8;

  /// The `n` argument for the `ESC t n` (select character code table) command,
  /// or `null` when no page switch should be emitted (e.g. [utf8]).
  ///
  /// These are the standard Epson TM-series / common-clone page numbers and
  /// are firmware dependent. `0` is the only universally fixed value (CP437).
  int? get escTCode => switch (this) {
    PrintlyCharset.latin => 0,
    PrintlyCharset.turkish => 13,
    PrintlyCharset.windows1254 => 48,
    // ISO-8859-9 has no dedicated ESC t page on most firmware; its high range
    // is byte-identical to WPC1254, so the WPC1254 page (48) is reused.
    PrintlyCharset.iso8859_9 => 48,
    PrintlyCharset.utf8 => null,
  };
}

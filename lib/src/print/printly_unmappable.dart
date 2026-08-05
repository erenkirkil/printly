/// Policy for input characters a machine-readable payload (QR, barcode)
/// cannot represent.
///
/// Exists because the two output paths used to disagree: `PrintJob.text`
/// degrades gracefully (unmappable runes print as `?`) while `PrintJob.qr`
/// threw an [ArgumentError] for the very same string — so auto-corrected
/// field input (`₺`, smart quotes, em dashes) crashed consumers at runtime.
/// The default remains [throwError]: silent data loss in a scannable code
/// stays strictly opt-in.
enum PrintlyUnmappable {
  /// Throw an [ArgumentError] — the pre-0.2.0 behaviour and the default.
  throwError,

  /// Substitute every unrepresentable rune with the replacement byte.
  replace,

  /// Convert runes with a readable equivalent (Turkish letters, smart
  /// quotes, dashes, ellipsis) via `TurkishCodePage.toLatin1` first, then
  /// substitute whatever remains.
  transliterate,
}

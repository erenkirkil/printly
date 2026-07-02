/// QR code error-correction level.
///
/// Higher levels tolerate more damage/smudging at the cost of denser modules
/// (and therefore a smaller module size on a fixed paper width). The percent
/// values are the fraction of codewords that can be restored.
enum PrintlyQrErrorLevel {
  /// Level L — ~7% recovery.
  low,

  /// Level M — ~15% recovery (a good default for receipts).
  medium,

  /// Level Q — ~25% recovery.
  quartile,

  /// Level H — ~30% recovery.
  high,
}

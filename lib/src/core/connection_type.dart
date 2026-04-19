/// Physical transport used to reach a [PrintlyDevice].
///
/// * [classic] — Bluetooth Classic (SPP / RFCOMM). Android only on the first
///   release; iOS Classic requires MFi certification and is out of scope.
/// * [ble] — Bluetooth Low Energy (GATT).
/// * [network] — TCP/IP (Ethernet or Wi-Fi), typically port 9100.
enum ConnectionType {
  /// Bluetooth Classic (SPP / RFCOMM).
  classic,

  /// Bluetooth Low Energy (GATT).
  ble,

  /// TCP/IP network printer (Ethernet or Wi-Fi).
  network;

  /// Stable wire code shared with the native side. Do not reorder.
  int get wireCode => switch (this) {
    ConnectionType.classic => 0,
    ConnectionType.ble => 1,
    ConnectionType.network => 2,
  };

  /// Decodes a [wireCode] received from the native side. Falls back to
  /// [ConnectionType.classic] for unknown values so a malformed event does not
  /// crash the stream.
  static ConnectionType fromWireCode(int code) => switch (code) {
    0 => ConnectionType.classic,
    1 => ConnectionType.ble,
    2 => ConnectionType.network,
    _ => ConnectionType.classic,
  };
}

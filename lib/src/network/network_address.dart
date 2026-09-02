/// A parsed `host:port` network target for a TCP printer.
///
/// Parsing splits on the *last* colon so IPv6 literals survive: a bare
/// `fe80::1:9100` is ambiguous, so IPv6 hosts must be bracketed
/// (`[fe80::1]:9100`) — the same convention URLs use. [canonical]
/// reproduces the bracketed form for IPv6 and the plain form otherwise.
class NetworkAddress {
  /// Creates an address from an already-split [host] and [port].
  const NetworkAddress(this.host, this.port);

  /// Host part — an IPv4 address, a bracket-stripped IPv6 address, or a
  /// hostname.
  final String host;

  /// TCP port (1–65535).
  final int port;

  /// Parses a `host:port` string. Throws [FormatException] when the port is
  /// missing, non-numeric, out of range, or the host is empty.
  static NetworkAddress parse(String address) {
    if (address.startsWith('[')) {
      final int close = address.indexOf(']');
      if (close == -1 || !address.startsWith(':', close + 1)) {
        throw FormatException('Invalid bracketed IPv6 address', address);
      }
      final String host = address.substring(1, close);
      if (host.isEmpty) throw FormatException('Empty host', address);
      final int port = _parsePort(address.substring(close + 2), address);
      return NetworkAddress(host, port);
    }
    final int sep = address.lastIndexOf(':');
    if (sep <= 0) throw FormatException('Expected host:port', address);
    final String host = address.substring(0, sep);
    final int port = _parsePort(address.substring(sep + 1), address);
    return NetworkAddress(host, port);
  }

  static int _parsePort(String raw, String source) {
    final int? port = int.tryParse(raw);
    if (port == null || port < 1 || port > 65535) {
      throw FormatException('Invalid port "$raw"', source);
    }
    return port;
  }

  /// The `host:port` form, bracketing an IPv6 host.
  String get canonical => host.contains(':') ? '[$host]:$port' : '$host:$port';
}

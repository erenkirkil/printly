import 'dart:async';
import 'dart:collection';
import 'dart:io';

import '../core/printly_device.dart';
import 'network_address.dart';
import 'tcp_printer_transport.dart';

/// Default raw ESC/POS TCP port (HP JetDirect / AppSocket).
const int kDefaultNetworkPort = 9100;

/// Default per-host TCP handshake deadline during a local subnet sweep.
///
/// On a wired or Wi-Fi LAN (`192.168.x.x`, `10.x.x.x`, `172.16-31.x.x`), a
/// healthy printer answers a `SYN` with `SYN-ACK` in 2–15 ms (or ~40–80 ms
/// when waking its Wi-Fi radio from power-save). A 200 ms budget gives ample
/// margin for Wi-Fi jitter while keeping a full 254-host sweep with
/// [kDefaultNetworkDiscoveryConcurrency] workers under ~1.2 seconds.
const Duration kDefaultNetworkProbeTimeout = Duration(milliseconds: 200);

/// Default number of concurrent TCP probes during a subnet sweep.
///
/// Capped at 48 so mobile OS file-descriptor limits and consumer router NAT /
/// ARP queues are never exhausted (`ceil(254 / 48) = 6` waves).
const int kDefaultNetworkDiscoveryConcurrency = 48;

/// Lists local IPv4 network interfaces as a map from interface name (e.g.
/// `'en0'`, `'wlan0'`) to its non-loopback IPv4 address strings; injectable so
/// unit tests can drive interface and RFC 1918 filtering deterministically
/// without touching the host machine's routing table or implementing
/// `dart:io`'s [NetworkInterface] (whose `addresses` return type changed from
/// `List<InternetAddress>` in Dart 3.12 to `List<InterfaceAddress>` in 3.13).
typedef NetworkInterfaceLister = Future<Map<String, List<String>>> Function();

/// Pure-Dart local network (LAN) thermal printer discovery over TCP port 9100.
///
/// Thermal printers with an Ethernet or Wi-Fi interface (Custom TK180, Epson
/// TM-T20/T88, Star, Bixolon, Rongta, Xprinter) listen for raw ESC/POS jobs on
/// TCP port 9100. Unlike office laser printers, most embedded thermal boards
/// do not advertise over mDNS/Bonjour (`_pdl-datastream._tcp`) and mobile OS
/// sandboxes (Android 10+ `/proc/net/arp` `EACCES`, iOS 11+ `<net/if_arp.h>`
/// omission) forbid reading MAC addresses from the ARP cache.
///
/// Discovery therefore sweeps the local `/24` IPv4 subnet with a **zero-write
/// TCP handshake probe**: each responsive host on [port] has its socket
/// immediately torn down via [Socket.destroy] without sending a single byte.
/// Never probing with `GS I` or `DLE EOT` prevents two real-world hardware
/// traps:
/// 1. Non-ESC/POS office printers on port 9100 (PCL/PostScript) print raw
///    probe bytes as garbage pages every time a scan runs.
/// 2. Embedded controllers that reject unknown commands (e.g. Custom TK180 on
///    unsupported `GS` sequences) print `COMMAND ERROR` on paper.
class NetworkPrinterDiscovery {
  const NetworkPrinterDiscovery._();

  static Future<Map<String, List<String>>> _defaultListInterfaces() async {
    final List<NetworkInterface> interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    return <String, List<String>>{
      for (final NetworkInterface iface in interfaces)
        iface.name: <String>[
          for (final InternetAddress addr in iface.addresses)
            if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback)
              addr.address,
        ],
    };
  }

  /// Sweeps a local IPv4 `/24` subnet (or an explicit [hosts] list) for
  /// devices accepting TCP connections on [port] (default `9100`) and returns
  /// a [PrintlyDevice.network] for each responsive address in deterministic
  /// host order.
  ///
  /// Candidate resolution order:
  /// 1. When [hosts] is supplied, only those hosts are probed (in order,
  ///    deduplicated).
  /// 2. When [subnet] is supplied (either a 3-octet `/24` prefix such as
  ///    `'192.168.0'` or a 4-octet IPv4 address such as `'192.168.0.5'`),
  ///    hosts `.1` through `.254` of that `/24` are probed (excluding the
  ///    4th octet when a full address is given).
  /// 3. When neither [subnet] nor [hosts] is supplied, active RFC 1918 private
  ///    IPv4 interfaces (`192.168.x.x`, `10.x.x.x`, `172.16–31.x.x`) are
  ///    queried via [NetworkInterface.list], cellular/VPN/tunnel interfaces
  ///    are filtered out, and each unique `/24` prefix is swept (excluding the
  ///    host device's own IP addresses).
  ///
  /// [activeAddresses] holds canonical `host:port` strings of TCP sessions
  /// already held open by [TcpPrinterTransport]. Any candidate matching an
  /// active session is included in the returned list **without** opening a
  /// second socket: embedded printer Ethernet stacks (`lwIP` / W5500) often
  /// accept only a single concurrent socket on port 9100, so probing an
  /// already-connected printer would either be refused (hiding the connected
  /// printer from scan results) or reset the active connection.
  static Future<List<PrintlyDevice>> discover({
    String? subnet,
    Iterable<String>? hosts,
    int port = kDefaultNetworkPort,
    Duration probeTimeout = kDefaultNetworkProbeTimeout,
    int concurrency = kDefaultNetworkDiscoveryConcurrency,
    Set<String> activeAddresses = const <String>{},
    SocketConnector? connector,
    NetworkInterfaceLister? listInterfaces,
  }) {
    if (port < 1 || port > 65535) {
      throw RangeError.range(port, 1, 65535, 'port');
    }
    if (concurrency < 1) {
      throw RangeError.value(concurrency, 'concurrency', 'must be at least 1');
    }
    if (probeTimeout <= Duration.zero) {
      throw ArgumentError.value(
        probeTimeout,
        'probeTimeout',
        'must be positive',
      );
    }
    if (subnet != null && hosts != null) {
      throw ArgumentError('pass either subnet or hosts, not both');
    }

    return _discoverAsync(
      subnet: subnet,
      hosts: hosts,
      port: port,
      probeTimeout: probeTimeout,
      concurrency: concurrency,
      activeAddresses: activeAddresses,
      connector: connector,
      listInterfaces: listInterfaces,
    );
  }

  static Future<List<PrintlyDevice>> _discoverAsync({
    required String? subnet,
    required Iterable<String>? hosts,
    required int port,
    required Duration probeTimeout,
    required int concurrency,
    required Set<String> activeAddresses,
    required SocketConnector? connector,
    required NetworkInterfaceLister? listInterfaces,
  }) async {
    final List<String> candidates = await _resolveCandidates(
      subnet: subnet,
      hosts: hosts,
      listInterfaces: listInterfaces ?? _defaultListInterfaces,
    );
    if (candidates.isEmpty) return const <PrintlyDevice>[];

    final SocketConnector connect = connector ?? Socket.connect;
    final List<bool> reachable = List<bool>.filled(candidates.length, false);
    int nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        final int index = nextIndex;
        if (index >= candidates.length) return;
        nextIndex = index + 1;

        final String host = candidates[index];
        final String canonical = NetworkAddress(host, port).canonical;
        if (activeAddresses.contains(canonical)) {
          reachable[index] = true;
          continue;
        }
        reachable[index] = await _probeHost(
          connect: connect,
          host: host,
          port: port,
          probeTimeout: probeTimeout,
        );
      }
    }

    final int workerCount = candidates.length < concurrency
        ? candidates.length
        : concurrency;
    await Future.wait(
      List<Future<void>>.generate(
        workerCount,
        (_) => worker(),
        growable: false,
      ),
    );

    final List<PrintlyDevice> found = <PrintlyDevice>[];
    for (int i = 0; i < candidates.length; i++) {
      if (!reachable[i]) continue;
      final String host = candidates[i];
      final String canonical = NetworkAddress(host, port).canonical;
      found.add(
        PrintlyDevice.network(host: host, port: port, name: 'TCP $canonical'),
      );
    }
    return List<PrintlyDevice>.unmodifiable(found);
  }

  /// Performs a zero-write TCP connect probe to `[host]:[port]` and destroys
  /// the socket immediately on success.
  static Future<bool> _probeHost({
    required SocketConnector connect,
    required String host,
    required int port,
    required Duration probeTimeout,
  }) async {
    // Two staggered deadlines, matching TcpPrinterTransport.connect:
    // `dart:io` gets a slightly longer backstop to release its OS descriptor,
    // while `pending.timeout(probeTimeout)` enforces the caller's exact
    // deadline even when a test injects a custom connector that ignores its
    // `timeout` parameter.
    final Future<Socket> pending = connect(
      host,
      port,
      timeout: probeTimeout + kNetworkTimeoutHeadroom,
    );
    try {
      final Socket socket = await pending.timeout(probeTimeout);
      socket.destroy();
      return true;
    } on TimeoutException {
      // Absorb late completions and errors so a slow host that finishes after
      // the probe deadline neither leaks a file descriptor nor triggers an
      // unhandled asynchronous error in the current Zone.
      unawaited(
        pending.then<void>(
          (Socket socket) => socket.destroy(),
          onError: (Object _, StackTrace _) {},
        ),
      );
      return false;
    } on Object {
      return false;
    }
  }

  static Future<List<String>> _resolveCandidates({
    required String? subnet,
    required Iterable<String>? hosts,
    required NetworkInterfaceLister listInterfaces,
  }) async {
    if (hosts != null) {
      final LinkedHashSet<String> unique = LinkedHashSet<String>();
      for (final String raw in hosts) {
        final String trimmed = raw.trim();
        if (trimmed.isNotEmpty) unique.add(trimmed);
      }
      return unique.toList(growable: false);
    }

    if (subnet != null) {
      return expandSubnet(subnet);
    }

    final Map<String, List<String>> interfaces;
    try {
      interfaces = await listInterfaces();
    } on Object {
      return const <String>[];
    }

    final LinkedHashSet<String> prefixes = LinkedHashSet<String>();
    final Set<String> ownIps = <String>{};
    for (final MapEntry<String, List<String>> entry in interfaces.entries) {
      if (!isCandidateInterfaceName(entry.key)) continue;
      for (final String ip in entry.value) {
        if (!isPrivateIpv4(ip)) continue;
        ownIps.add(ip);
        final int lastDot = ip.lastIndexOf('.');
        if (lastDot > 0) {
          prefixes.add(ip.substring(0, lastDot));
        }
      }
    }

    if (prefixes.isEmpty) return const <String>[];

    final List<String> candidates = <String>[];
    for (final String prefix in prefixes) {
      for (int host = 1; host <= 254; host++) {
        final String ip = '$prefix.$host';
        if (!ownIps.contains(ip)) {
          candidates.add(ip);
        }
      }
    }
    return candidates;
  }

  /// Expands a `/24` IPv4 [subnet] (either `'a.b.c'` or `'a.b.c.d'`) into
  /// host addresses `.1` through `.254`. When a 4-octet address `'a.b.c.d'` is
  /// passed, `'a.b.c.d'` itself is excluded from the returned list.
  ///
  /// Throws [FormatException] if [subnet] is not a valid 3- or 4-octet IPv4
  /// specification.
  static List<String> expandSubnet(String subnet) {
    final String trimmed = subnet.trim();
    final List<String> parts = trimmed.split('.');
    if (parts.length != 3 && parts.length != 4) {
      throw FormatException(
        'invalid IPv4 /24 subnet "$subnet" — expected "a.b.c" or "a.b.c.d"',
      );
    }
    final List<int> octets = <int>[];
    for (final String part in parts) {
      final int? v = int.tryParse(part);
      if (v == null || v < 0 || v > 255) {
        throw FormatException('invalid IPv4 octet "$part" in subnet "$subnet"');
      }
      octets.add(v);
    }

    final String prefix = '${octets[0]}.${octets[1]}.${octets[2]}';
    final int? excludeHost = octets.length == 4 ? octets[3] : null;
    final List<String> result = <String>[];
    for (int i = 1; i <= 254; i++) {
      if (i == excludeHost) continue;
      result.add('$prefix.$i');
    }
    return result;
  }

  /// Whether [ip] is an RFC 1918 private IPv4 address (`10.0.0.0/8`,
  /// `172.16.0.0/12`, or `192.168.0.0/16`).
  static bool isPrivateIpv4(String ip) {
    final List<String> parts = ip.split('.');
    if (parts.length != 4) return false;
    final int? a = int.tryParse(parts[0]);
    final int? b = int.tryParse(parts[1]);
    final int? c = int.tryParse(parts[2]);
    final int? d = int.tryParse(parts[3]);
    if (a == null || b == null || c == null || d == null) return false;
    if (a < 0 ||
        a > 255 ||
        b < 0 ||
        b > 255 ||
        c < 0 ||
        c > 255 ||
        d < 0 ||
        d > 255) {
      return false;
    }
    if (a == 10) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 192 && b == 168) return true;
    return false;
  }

  /// Whether a network interface [name] is a plausible LAN (Wi-Fi / Ethernet)
  /// interface rather than cellular data, VPN/tunnel, loopback, or virtual
  /// peer-to-peer link.
  static bool isCandidateInterfaceName(String name) {
    final String lower = name.toLowerCase();
    const List<String> rejectedPrefixes = <String>[
      'lo',
      'pdp_ip',
      'rmnet',
      'ccmni',
      'clat',
      'wwan',
      'ip_vti',
      'tun',
      'tap',
      'utun',
      'ppp',
      'ipsec',
      'wg',
      'tailscale',
      'zt',
      'gif',
      'stf',
      'awdl',
      'llw',
      'anpi',
    ];
    for (final String prefix in rejectedPrefixes) {
      if (lower.startsWith(prefix)) return false;
    }
    return true;
  }
}

import '../platform/wire_protocol.dart';
import 'connection_type.dart';

/// Immutable descriptor of a discoverable or remembered printer.
///
/// One record models one physical radio, not one advertisement. A dual-mode
/// printer (e.g. the Cashino PTP-II) broadcasts both a Bluetooth Classic
/// inquiry response and a BLE advertisement for the same MAC address; before
/// this model existed those were two separate [PrintlyDevice] records (keyed
/// on `type:address`) and the same physical printer showed up twice in scan
/// lists. Equality and [dedupKey] are now address-only, so Classic and BLE
/// sightings of the same radio collapse into a single record whose
/// [availableTransports] lists every transport it was seen on. Which
/// transport to actually use is a decision for `connect()`, not for this
/// model — a caller connecting to a dual-mode printer picks BLE or Classic
/// explicitly.
class PrintlyDevice {
  /// Creates an immutable device descriptor. [address] and
  /// [availableTransports] are required; the remaining fields are scan
  /// metadata and may be refreshed later via [copyWith] or [mergeWith].
  ///
  /// [availableTransports] must be non-empty — a device with no reachable
  /// transport is not a valid discovery result.
  const PrintlyDevice({
    required this.address,
    required this.availableTransports,
    this.name,
    this.rssi,
    this.isBonded = false,
    this.seenInScan = true,
  }) : assert(
         availableTransports.length > 0,
         'availableTransports must not be empty',
       );

  /// Creates a descriptor for a network (TCP) printer. Host + port become the
  /// [address] in the canonical `host:port` form so dedup still works.
  factory PrintlyDevice.network({
    required String host,
    int port = 9100,
    String? name,
  }) => PrintlyDevice(
    address: '$host:$port',
    availableTransports: const <ConnectionType>{ConnectionType.network},
    name: name,
  );

  /// Transport-unique identifier. MAC address for Classic/BLE on Android,
  /// peripheral UUID for BLE on iOS, and `host:port` for network devices.
  final String address;

  /// Every transport this physical radio has been observed to support.
  /// A dual-mode printer (Classic + BLE) has two elements here; the choice
  /// of which one to actually open a link over belongs to `connect()`.
  ///
  /// Not defensively copied — wrapping it in `Set.unmodifiable` in the
  /// constructor would prevent this class staying `const`. Treat it as
  /// immutable regardless: [copyWith] and [mergeWith] both always allocate a
  /// fresh set rather than mutating this one, so a caller that never mutates
  /// the set it was handed is safe either way.
  final Set<ConnectionType> availableTransports;

  /// Advertised friendly name, when provided by the transport. May be `null`
  /// for BLE peripherals that only advertise their service UUID.
  final String? name;

  /// Last observed signal strength (dBm). BLE-only; `null` for Classic and
  /// network devices.
  final int? rssi;

  /// Whether the device is already paired/bonded at the OS level. Only
  /// meaningful for Classic and BLE.
  final bool isBonded;

  /// Whether this record reflects an actual scan sighting rather than a
  /// bonded/persisted seed. Native Classic discovery seeds the list from the
  /// OS bond cache before any inquiry result arrives, sending `false` for
  /// those entries; a device with [seenInScan] `false` may not currently be
  /// in range — a connect attempt against it can still end in a timeout.
  /// Once a record has been confirmed by an actual scan, [mergeWith] never
  /// flips it back to `false`.
  final bool seenInScan;

  /// Whether [name] is present and holds more than just whitespace. Bonded
  /// seeds and some BLE advertisements carry an empty or blank name field;
  /// treating that the same as "no name" keeps UI fallback logic in one
  /// place instead of every call site re-deriving this check.
  bool get hasName => name != null && name!.trim().isNotEmpty;

  /// Stable dedup key used by the scan stream to merge advertisements of the
  /// same physical radio — the bare [address]. Two [PrintlyDevice] records
  /// with the same address are the same printer even if they were observed
  /// over different transports.
  String get dedupKey => address;

  /// Returns a new [PrintlyDevice] with the supplied scan-time fields merged
  /// in. Used to refresh [rssi] / [name] / [isBonded] / [seenInScan] /
  /// [availableTransports] without allocating a new identity. Null arguments
  /// preserve the existing value.
  PrintlyDevice copyWith({
    String? name,
    int? rssi,
    bool? isBonded,
    bool? seenInScan,
    Set<ConnectionType>? availableTransports,
  }) => PrintlyDevice(
    address: address,
    availableTransports: availableTransports ?? this.availableTransports,
    name: name ?? this.name,
    rssi: rssi ?? this.rssi,
    isBonded: isBonded ?? this.isBonded,
    seenInScan: seenInScan ?? this.seenInScan,
  );

  /// Merges a fresh advertisement [other] (same [address]) into this record:
  /// transports union, [isBonded]/[seenInScan] OR (once seen, always seen —
  /// a bonded seed later confirmed by inquiry must not flip back), [name]
  /// prefers the non-null and non-blank newest, [rssi] prefers the latest
  /// reading. A blank/whitespace advertised name (real BLE behavior) must not
  /// clobber a genuine name learned from the other transport — that would flip
  /// [hasName], render "(unnamed)" in UIs, and could trigger a spurious
  /// classicFirst BLE fallback round.
  PrintlyDevice mergeWith(PrintlyDevice other) {
    assert(other.address == address, 'mergeWith requires the same address');
    return PrintlyDevice(
      address: address,
      availableTransports: <ConnectionType>{
        ...availableTransports,
        ...other.availableTransports,
      },
      name: (other.hasName ? other.name : null) ?? name,
      rssi: other.rssi ?? rssi,
      isBonded: isBonded || other.isBonded,
      seenInScan: seenInScan || other.seenInScan,
    );
  }

  /// JSON representation used by last-device persistence only — this is not
  /// the wire format sent to native (see `MethodChannelPrintly` for that).
  /// Scan-only fields ([rssi], [isBonded], [seenInScan]) are intentionally
  /// omitted — they are not stable across sessions. [availableTransports] is
  /// stored as a wire-code-sorted `List<int>` under `'transports'`.
  Map<String, Object?> toJson() => <String, Object?>{
    'address': address,
    'transports':
        (availableTransports.toList()..sort(
              (ConnectionType a, ConnectionType b) =>
                  a.wireCode.compareTo(b.wireCode),
            ))
            .map((ConnectionType t) => t.wireCode)
            .toList(),
    'name': name,
  };

  /// Reverse of [toJson]. Understands both the current `'transports'` (list
  /// of wire codes) format and the 0.1.x persisted `'type'` (single int)
  /// format, so a last-connected device saved by an earlier version of this
  /// package still loads instead of being silently dropped on upgrade.
  /// Returns `null` when required fields are missing or malformed so the
  /// caller can silently ignore stale persisted payloads instead of crashing
  /// on launch.
  static PrintlyDevice? fromJson(Map<String, Object?> json) {
    final Object? address = json['address'];
    if (address is! String) return null;

    final Object? transportCodes = json['transports'];
    final Set<ConnectionType> transports;
    if (transportCodes is List) {
      transports = transportCodes
          .whereType<int>()
          .map(ConnectionType.fromWireCode)
          .toSet();
      if (transports.isEmpty) return null;
    } else {
      // Legacy 0.1.x format: a single `'type'` int field.
      final Object? typeCode = json['type'];
      if (typeCode is! int) return null;
      transports = <ConnectionType>{ConnectionType.fromWireCode(typeCode)};
    }

    return PrintlyDevice(
      address: address,
      availableTransports: transports,
      name: json['name'] is String ? json['name'] as String : null,
    );
  }

  /// Decodes a single native scan-event map into a [PrintlyDevice]. Native
  /// events always describe one transport at a time (`keyType`), so the
  /// result always has exactly one element in [availableTransports]; merging
  /// same-address sightings across transports into one record with several
  /// transports is the scan controller's job ([mergeWith]), not this
  /// decoder's. `keySeenInScan` absent (or not a bool) defaults to `true` —
  /// only bonded-cache seeding sends `false` explicitly. Returns `null` for
  /// malformed payloads so a single bad event does not tear down the stream.
  static PrintlyDevice? fromWireMap(Map<Object?, Object?> map) {
    final Object? address = map[WireProtocol.keyAddress];
    final Object? typeCode = map[WireProtocol.keyType];
    if (address is! String || typeCode is! int) return null;
    final Object? seenInScan = map[WireProtocol.keySeenInScan];
    return PrintlyDevice(
      address: address,
      availableTransports: <ConnectionType>{
        ConnectionType.fromWireCode(typeCode),
      },
      name: map[WireProtocol.keyName] is String
          ? map[WireProtocol.keyName] as String
          : null,
      rssi: map[WireProtocol.keyRssi] is int
          ? map[WireProtocol.keyRssi] as int
          : null,
      isBonded: map[WireProtocol.keyIsBonded] is bool
          ? map[WireProtocol.keyIsBonded] as bool
          : false,
      seenInScan: seenInScan is bool ? seenInScan : true,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PrintlyDevice &&
          other.runtimeType == runtimeType &&
          other.address == address);

  @override
  int get hashCode => address.hashCode;

  @override
  String toString() =>
      'PrintlyDevice($address, transports='
      '${availableTransports.map((ConnectionType t) => t.name).join("+")}'
      '${name != null ? ', "$name"' : ''}'
      '${rssi != null ? ', rssi=$rssi' : ''}${isBonded ? ', bonded' : ''}'
      '${!seenInScan ? ', unseen' : ''})';
}

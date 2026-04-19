import 'connection_type.dart';

/// Immutable descriptor of a discoverable or remembered printer.
///
/// Two devices are considered the same when their [address] and [type] match,
/// which is the dedup key used by the scan stream to merge Classic and BLE
/// advertisements of the same radio. Mutable scan metadata like [rssi] is
/// ignored for equality so a stronger/weaker signal does not introduce
/// duplicates in consumer lists.
class PrintlyDevice {
  /// Creates an immutable device descriptor. Only [address] and [type] are
  /// required; the remaining fields are scan metadata and may be refreshed
  /// later via [copyWith].
  const PrintlyDevice({
    required this.address,
    required this.type,
    this.name,
    this.rssi,
    this.isBonded = false,
  });

  /// Creates a descriptor for a network (TCP) printer. Host + port become the
  /// [address] in the canonical `host:port` form so dedup still works.
  factory PrintlyDevice.network({
    required String host,
    int port = 9100,
    String? name,
  }) => PrintlyDevice(
    address: '$host:$port',
    type: ConnectionType.network,
    name: name,
  );

  /// Transport-unique identifier. MAC address for Classic/BLE on Android,
  /// peripheral UUID for BLE on iOS, and `host:port` for network devices.
  final String address;

  /// Transport used to reach the device.
  final ConnectionType type;

  /// Advertised friendly name, when provided by the transport. May be `null`
  /// for BLE peripherals that only advertise their service UUID.
  final String? name;

  /// Last observed signal strength (dBm). BLE-only; `null` for Classic and
  /// network devices.
  final int? rssi;

  /// Whether the device is already paired/bonded at the OS level. Only
  /// meaningful for Classic and BLE.
  final bool isBonded;

  /// Stable composite key used by the scan stream to dedup advertisements
  /// ("only one entry per physical radio + transport combination").
  String get dedupKey => '${type.name}:$address';

  /// Returns a new [PrintlyDevice] with the supplied scan-time fields merged
  /// in. Used by the scan controller to refresh [rssi] / [name] / [isBonded]
  /// without allocating a new identity. Null arguments preserve the existing
  /// value.
  PrintlyDevice copyWith({String? name, int? rssi, bool? isBonded}) =>
      PrintlyDevice(
        address: address,
        type: type,
        name: name ?? this.name,
        rssi: rssi ?? this.rssi,
        isBonded: isBonded ?? this.isBonded,
      );

  /// JSON representation used by last-device persistence. Scan-only fields
  /// ([rssi], [isBonded]) are intentionally omitted — they are not stable
  /// across sessions.
  Map<String, Object?> toJson() => <String, Object?>{
    'address': address,
    'type': type.wireCode,
    'name': name,
  };

  /// Reverse of [toJson]. Returns `null` when required fields are missing or
  /// malformed so the caller can silently ignore stale persisted payloads
  /// instead of crashing on launch.
  static PrintlyDevice? fromJson(Map<String, Object?> json) {
    final Object? address = json['address'];
    final Object? typeCode = json['type'];
    if (address is! String || typeCode is! int) return null;
    return PrintlyDevice(
      address: address,
      type: ConnectionType.fromWireCode(typeCode),
      name: json['name'] is String ? json['name'] as String : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PrintlyDevice && other.address == address && other.type == type;

  @override
  int get hashCode => Object.hash(address, type);

  @override
  String toString() =>
      'PrintlyDevice(${type.name}, $address${name != null ? ', "$name"' : ''}'
      '${rssi != null ? ', rssi=$rssi' : ''}${isBonded ? ', bonded' : ''})';
}

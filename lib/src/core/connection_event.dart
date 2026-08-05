import 'connection_state.dart';
import 'printly_device.dart';

/// Single connection-state transition reported by the native side.
///
/// These events flow on a raw platform stream and are fanned out to
/// per-device broadcast streams by the Dart-side connection controller.
class PrintlyConnectionEvent {
  /// Creates an event describing the current [state] of [device]. A non-null
  /// [failureReason] is only meaningful when [state] is
  /// [ConnectionState.error].
  const PrintlyConnectionEvent({
    required this.device,
    required this.state,
    this.failureReason,
  });

  /// Device this event applies to.
  final PrintlyDevice device;

  /// State reported by the transport.
  final ConnectionState state;

  /// Human-readable reason attached to an [ConnectionState.error] event.
  /// Not localised — intended for diagnostics and log output.
  final String? failureReason;

  /// Decodes the raw map sent across the event channel. Returns `null` for
  /// malformed payloads so the Dart side can silently drop them instead of
  /// tearing the stream down.
  static PrintlyConnectionEvent? fromMap(Map<dynamic, dynamic> map) {
    final Object? device = map['device'];
    final Object? stateCode = map['state'];
    if (device is! Map || stateCode is! int) return null;
    // Native connection events describe one transport at a time, same as
    // scan events — route through the same wire decoder so a dual-mode
    // radio's connection event still resolves to a valid single-transport
    // record (ConnectionController keys by address, so this is harmless).
    final PrintlyDevice? decoded = PrintlyDevice.fromWireMap(
      device.cast<Object?, Object?>(),
    );
    if (decoded == null) return null;
    return PrintlyConnectionEvent(
      device: decoded,
      state: ConnectionState.fromWireCode(stateCode),
      failureReason: map['failureReason'] is String
          ? map['failureReason'] as String
          : null,
    );
  }

  @override
  String toString() =>
      'PrintlyConnectionEvent(${device.dedupKey}, ${state.name}'
      '${failureReason != null ? ', reason="$failureReason"' : ''})';
}

import 'dart:async' show TimeoutException;

/// Machine-readable error codes shared across the Dart, Android, and iOS
/// layers.
///
/// Every code corresponds to one `wireName` string that the native sides emit
/// as a `PlatformException` code/message or as a connection-event
/// `failureReason`. The same condition maps to the same code on both
/// platforms, so consumers can `switch` on this enum instead of parsing
/// platform-dependent strings.
enum PrintlyErrorCode {
  /// A required Bluetooth runtime permission is missing or was denied.
  permissionDenied('permission_denied'),

  /// The device has no usable Bluetooth adapter.
  bluetoothUnavailable('bluetooth_unavailable'),

  /// The Bluetooth adapter is present but switched off.
  bluetoothNotPoweredOn('bluetooth_not_powered_on'),

  /// Starting the native scan failed for a reason not covered by a more
  /// specific code.
  scanFailed('start_scan_failed'),

  /// A connect attempt did not reach a terminal state within the timeout.
  connectTimeout('connect_timeout'),

  /// A connect attempt failed (refused, out of range, paging failure, …).
  connectFailed('connect_failed'),

  /// The link dropped — either mid-connect or on an established connection.
  disconnected('disconnected'),

  /// iOS only: the peripheral UUID is not known to CoreBluetooth (it must be
  /// discovered by a scan before it can be connected).
  peripheralUnknown('peripheral_unknown'),

  /// A write was attempted with no open link for the device.
  notConnected('not_connected'),

  /// BLE only: the link is up but service discovery has not resolved a
  /// writable characteristic yet.
  notReady('not_ready'),

  /// A write was attempted while a previous write is still in flight.
  writeBusy('write_busy'),

  /// The printer did not acknowledge the written data within the watchdog
  /// interval (dead link or full buffer) — usually worth a reconnect + retry.
  writeTimeout('write_timeout'),

  /// A write failed for a reason not covered by a more specific code.
  writeFailed('write_failed'),

  /// Network (Ethernet/WiFi) transport is not implemented yet.
  networkNotSupported('network_not_supported'),

  /// iOS cannot open Bluetooth Classic links to non-MFi devices; use BLE.
  classicRequiresMfi('classic_requires_mfi'),

  /// The operation is not implemented on this platform yet.
  unsupportedPlatform('unsupported_platform'),

  /// Anything the SDK could not classify. The original platform message is
  /// preserved in [PrintlyException.message].
  unknown('unknown');

  const PrintlyErrorCode(this.wireName);

  /// The string form of this code as it crosses the platform channel.
  final String wireName;

  /// Resolves a wire string back to its code, or [unknown] when the string
  /// is null or not part of the shared vocabulary.
  static PrintlyErrorCode fromWireName(String? name) {
    if (name == null) return unknown;
    for (final PrintlyErrorCode code in values) {
      if (code.wireName == name) return code;
    }
    return unknown;
  }
}

/// Base type of every error the printly SDK throws.
///
/// The hierarchy is sealed, so a `switch` over a caught [PrintlyException]
/// is exhaustive:
///
/// ```dart
/// try {
///   await Printly.instance.connect(device);
/// } on PrintlyConnectionException catch (e) {
///   if (e.code == PrintlyErrorCode.connectTimeout) retryLater();
/// } on PrintlyPermissionException {
///   await Printly.instance.requestPermissions();
/// }
/// ```
sealed class PrintlyException implements Exception {
  /// Creates an exception carrying a machine-readable [code] and the
  /// human-readable platform [message].
  const PrintlyException(this.code, this.message);

  /// Machine-readable classification — stable across platforms.
  final PrintlyErrorCode code;

  /// Human-readable detail, typically the raw native message. Do not
  /// `switch` on this; use [code].
  final String message;

  @override
  String toString() => '$runtimeType(${code.wireName}): $message';
}

/// A required Bluetooth permission is missing. Ask the user via
/// `Printly.instance.requestPermissions()` (or send them to the app settings
/// when permanently denied).
final class PrintlyPermissionException extends PrintlyException {
  /// Creates a permission failure with the originating [message].
  const PrintlyPermissionException(String message)
    : super(PrintlyErrorCode.permissionDenied, message);
}

/// Starting or running a device scan failed.
final class PrintlyScanException extends PrintlyException {
  /// Creates a scan failure classified as [code].
  const PrintlyScanException(super.code, super.message);
}

/// Opening (or keeping) a connection failed. The [code] distinguishes
/// timeouts, refusals, and dropped links.
base class PrintlyConnectionException extends PrintlyException {
  /// Creates a connection failure classified as [code].
  const PrintlyConnectionException(super.code, super.message);
}

/// A connect attempt timed out.
///
/// Also implements [TimeoutException], so pre-existing
/// `on TimeoutException` handlers keep working.
final class PrintlyConnectionTimeoutException extends PrintlyConnectionException
    implements TimeoutException {
  /// Creates a timeout failure after waiting [duration].
  PrintlyConnectionTimeoutException(this.duration)
    : super(
        PrintlyErrorCode.connectTimeout,
        'connect timed out after ${duration.inMilliseconds} ms',
      );

  @override
  final Duration duration;
}

/// Writing print data to the device failed. [PrintlyErrorCode.writeTimeout]
/// and [PrintlyErrorCode.disconnected] are usually recoverable with a
/// reconnect + retry; [PrintlyErrorCode.notConnected] means connect first.
final class PrintlyWriteException extends PrintlyException {
  /// Creates a write failure classified as [code].
  const PrintlyWriteException(super.code, super.message);
}

/// The requested operation is not available — either not yet implemented
/// (network transport, iOS printing before Sprint 6) or impossible on the
/// platform (Bluetooth Classic on iOS without MFi).
final class PrintlyUnsupportedException extends PrintlyException {
  /// Creates an unsupported-operation failure classified as [code].
  const PrintlyUnsupportedException(super.code, super.message);
}

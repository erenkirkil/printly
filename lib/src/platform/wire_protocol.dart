/// Single source of truth for the strings that cross the platform channel.
///
/// The native counterparts live in `WireCodes.kt` (Android) and
/// `WireCodes.swift` (iOS); the three files are kept in sync manually, the
/// same way the integer wire codes already are. Every channel name, method
/// name, and payload key must be referenced from here — never inlined — so
/// a drift can only happen in one visible place per platform.
abstract final class WireProtocol {
  // Channel names -----------------------------------------------------------

  /// The shared method channel.
  static const String methodChannel = 'printly';

  /// Event channel streaming Bluetooth adapter state codes.
  static const String adapterStateChannel = 'printly/adapter_state';

  /// Event channel streaming discovered-device maps.
  static const String scanResultsChannel = 'printly/scan_results';

  /// Event channel streaming per-device connection events.
  static const String connectionEventsChannel = 'printly/connection_events';

  // Method names -------------------------------------------------------------

  /// Returns the native OS version string.
  static const String mGetPlatformVersion = 'getPlatformVersion';

  /// Android only: returns `Build.VERSION.SDK_INT`.
  static const String mGetAndroidSdkInt = 'getAndroidSdkInt';

  /// Opens the system Bluetooth settings (Android) or app settings (iOS).
  static const String mOpenBluetoothSettings = 'openBluetoothSettings';

  /// Requests that the radio be turned on in place: Android's
  /// `ACTION_REQUEST_ENABLE` system dialog, or iOS's power-alert
  /// `CBCentralManager`. Returns whether the request was shown — the actual
  /// enable/decline outcome must be observed on [adapterStateChannel].
  static const String mRequestEnableBluetooth = 'requestEnableBluetooth';

  /// Starts a device scan for the transports in [keyTypes].
  static const String mStartScan = 'startScan';

  /// Stops the running scan.
  static const String mStopScan = 'stopScan';

  /// Opens a link to the device in [keyDevice].
  static const String mConnect = 'connect';

  /// Closes the link to the device in [keyDevice].
  static const String mDisconnect = 'disconnect';

  /// Writes the bytes in [keyBytes] to the device in [keyDevice].
  static const String mWrite = 'write';

  /// Whether the OS location service is enabled (Android below API 31 needs it
  /// for scanning; `true` elsewhere).
  static const String mIsLocationServiceEnabled = 'isLocationServiceEnabled';

  /// Opens the system location settings page (Android only).
  static const String mOpenLocationSettings = 'openLocationSettings';

  // Payload keys ---------------------------------------------------------

  /// A serialised device map (see `PrintlyDevice.toJson`).
  static const String keyDevice = 'device';

  /// Connect timeout in milliseconds (int).
  static const String keyTimeoutMs = 'timeoutMs';

  /// Transport wire codes to scan (List of int).
  static const String keyTypes = 'types';

  /// Print payload (Uint8List).
  static const String keyBytes = 'bytes';

  /// Device MAC address (Android) or peripheral UUID (iOS).
  static const String keyAddress = 'address';

  /// Transport wire code (int).
  static const String keyType = 'type';

  /// Advertised or bonded device name.
  static const String keyName = 'name';

  /// Signal strength (int, BLE only).
  static const String keyRssi = 'rssi';

  /// Whether the device is bonded/paired (bool).
  static const String keyIsBonded = 'isBonded';

  /// Connection state wire code (int) in connection events.
  static const String keyState = 'state';

  /// Failure-reason wire string in connection events (see
  /// `PrintlyErrorCode.wireName`).
  static const String keyFailureReason = 'failureReason';

  /// Whether the device was actually observed during this scan (bool);
  /// absent means true. Classic bonded seeding sends false.
  static const String keySeenInScan = 'seenInScan';
}

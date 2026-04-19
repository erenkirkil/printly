/// Platform-agnostic Bluetooth adapter state.
///
/// Maps to both Android (`BluetoothAdapter.STATE_*`) and iOS
/// (`CBManagerState`) native values, with extra semantics for permission
/// and hardware availability that neither platform exposes uniformly.
enum BluetoothAdapterState {
  /// Bluetooth is on and ready to use.
  poweredOn,

  /// Bluetooth is off. The user can enable it from system settings.
  poweredOff,

  /// The app does not have permission to use Bluetooth.
  ///
  /// On iOS this maps to `CBManagerState.unauthorized`. On Android this
  /// is synthesized by the plugin when required runtime permissions
  /// (`BLUETOOTH_SCAN` / `BLUETOOTH_CONNECT` on API 31+, `BLUETOOTH` +
  /// `ACCESS_FINE_LOCATION` on older releases) have not been granted.
  unauthorized,

  /// The device has no Bluetooth hardware or it is not supported.
  unsupported,

  /// Bluetooth is transitioning between on and off.
  resetting,

  /// The adapter state has not been determined yet. Default value before
  /// the first event is received from the platform.
  unknown;

  /// Maps a raw integer code coming from the platform channel to an
  /// [BluetoothAdapterState] value.
  ///
  /// The native side sends these codes (kept in sync between Kotlin and
  /// Swift implementations):
  ///
  /// | code | meaning       |
  /// |------|---------------|
  /// | 0    | [unknown]     |
  /// | 1    | [resetting]   |
  /// | 2    | [unsupported] |
  /// | 3    | [unauthorized]|
  /// | 4    | [poweredOff]  |
  /// | 5    | [poweredOn]   |
  ///
  /// Unrecognised codes fall back to [unknown].
  static BluetoothAdapterState fromCode(int code) {
    switch (code) {
      case 1:
        return BluetoothAdapterState.resetting;
      case 2:
        return BluetoothAdapterState.unsupported;
      case 3:
        return BluetoothAdapterState.unauthorized;
      case 4:
        return BluetoothAdapterState.poweredOff;
      case 5:
        return BluetoothAdapterState.poweredOn;
      case 0:
      default:
        return BluetoothAdapterState.unknown;
    }
  }
}

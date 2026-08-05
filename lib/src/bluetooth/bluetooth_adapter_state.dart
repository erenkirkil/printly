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

  /// The app is not authorised to use Bluetooth.
  ///
  /// Emitted only by iOS (`CBManagerState.unauthorized`), where CoreBluetooth
  /// itself gates radio access behind the permission. Android stopped
  /// synthesizing this value in 0.2.0: the plugin used to fold missing
  /// runtime permissions into the adapter stream, but Android never
  /// re-broadcasts on permission changes, so the value froze as
  /// `unauthorized` until process restart. Query permissions with
  /// `Printly.instance.checkPermissions()` instead.
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

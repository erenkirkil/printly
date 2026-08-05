import 'package:permission_handler/permission_handler.dart' as ph;

/// The permission set printly evaluates on the given platform/API level.
///
/// Lives in a non-exported library so the `permission_handler` type never
/// reaches the public API surface, while `checkPermissions()` and
/// `requestPermissions()` still share one source of truth and tests can
/// import it directly via `package:printly/src/...`.
///
/// On Android 12+ (API 31+) only `BLUETOOTH_SCAN`/`BLUETOOTH_CONNECT` are
/// evaluated; the legacy/location permissions are capped at
/// `maxSdkVersion=30` in the manifest and would wrongly poison the
/// aggregate. On Android 11 and below the legacy pair applies. Everywhere
/// else only `bluetooth`.
List<ph.Permission> requiredBluetoothPermissions({
  required bool isAndroid,
  required int sdkInt,
}) {
  if (isAndroid) {
    return sdkInt >= 31
        ? <ph.Permission>[
            ph.Permission.bluetoothScan,
            ph.Permission.bluetoothConnect,
          ]
        : <ph.Permission>[
            ph.Permission.bluetooth,
            ph.Permission.locationWhenInUse,
          ];
  }
  return <ph.Permission>[ph.Permission.bluetooth];
}

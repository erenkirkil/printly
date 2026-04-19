## 0.1.0-dev

Initial release preparation. See [`docs/sprints.md`](docs/sprints.md) for the roadmap toward the first public release.

### Sprint 3 — Device discovery & connection

- Core models: `ConnectionType`, `ConnectionState`, `PrintlyDevice`, and `PrintlyConnectionEvent` with stable integer wire codes shared across Dart/Kotlin/Swift.
- `ScanController` with re-entrancy guards (concurrent `startScan` calls share one native scan), dedup/merge by transport + address, and automatic timeout.
- `ConnectionController` with per-device state streams, `activeDeviceStream`, serialised device switching (disconnect previous → connect new), and failure-reason tracking.
- Persistence via `LastDeviceStore` (SharedPreferences) for the last-connected device and an opt-in auto-reconnect flag.
- Public API on `Printly.instance`: `startScan`, `stopScan`, `devicesStream`, `connect`, `disconnect`, `connectionStateOf`, `activeDeviceStream`, `loadLastConnectedDevice`, `reconnectLastDevice`, `enableAutoReconnect`.
- Android native split into layered files (adapter/scan/connection/util) with modern, non-deprecated APIs: `BluetoothLeScanner`, `BluetoothDevice.TRANSPORT_LE`, API 33+ `getParcelableExtra` overloads. Classic RFCOMM connects run on a dedicated IO thread with socket-close based timeout.
- iOS native split around a shared `CentralController` that owns a single `CBCentralManager`, so the Bluetooth permission prompt only appears once. BLE scan + connect implemented; Classic rejects with `classic_requires_mfi`; network deferred.
- Example app extended with start/stop scan, discovered devices list with per-device connect/disconnect buttons, and active-device banner.

### Sprint 2 — Bluetooth state & permissions

- `BluetoothAdapterState` enum with 6 values and stable integer wire codes.
- Live adapter state stream (`Printly.instance.adapterState`) backed by a broadcast receiver on Android and a lazily instantiated `CBCentralManager` on iOS.
- Cached `currentAdapterState` and synchronous `isBluetoothAvailable` getter via `BluetoothManager`.
- `requestPermissions()` with platform-specific flows (Android 12+ vs 11-, iOS) and aggregated `PermissionStatus` result.
- `openBluetoothSettings()` and `openAppSettings()` helpers.
- Example app rewritten around a Bluetooth playground page.

### Sprint 1 — Foundation & scaffold

- Package scaffold, CI (analyze + test + publish dry-run), and strict lint baseline.

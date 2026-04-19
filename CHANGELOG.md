## 0.1.0-dev

Initial release preparation. See [`docs/sprints.md`](docs/sprints.md) for the roadmap toward the first public release.

### Sprint 2 — Bluetooth state & permissions

- `BluetoothAdapterState` enum with 6 values and stable integer wire codes.
- Live adapter state stream (`Printly.instance.adapterState`) backed by a broadcast receiver on Android and a lazily instantiated `CBCentralManager` on iOS.
- Cached `currentAdapterState` and synchronous `isBluetoothAvailable` getter via `BluetoothManager`.
- `requestPermissions()` with platform-specific flows (Android 12+ vs 11-, iOS) and aggregated `PermissionStatus` result.
- `openBluetoothSettings()` and `openAppSettings()` helpers.
- Example app rewritten around a Bluetooth playground page.

### Sprint 1 — Foundation & scaffold

- Package scaffold, CI (analyze + test + publish dry-run), and strict lint baseline.

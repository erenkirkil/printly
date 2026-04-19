# printly

Production-grade thermal printer SDK for Flutter. Bluetooth Classic, BLE, Ethernet/WiFi, ESC/POS, Turkish charset (CP857), built-in permission management.

> 🚧 **Under active development.** Targeting `v0.1.0` release at the end of Sprint 6. See [`docs/sprints.md`](docs/sprints.md) for the roadmap and [`docs/package_roadmap.md`](docs/package_roadmap.md) for architectural details.

## Planned features

- Bluetooth **Classic + BLE + Ethernet/WiFi** in a single plugin
- Enum-based `BluetoothAdapterState` (not bool)
- Per-device `ConnectionState` streams
- Built-in permission flow (Android 12+ runtime permissions, iOS Info.plist)
- Turkish character support (CP857 primary, WPC1254 fallback)
- Smart QR / barcode sizing for 58mm and 80mm paper
- Android ethernet binding (`bindProcessToNetwork`)
- Widget → raster → print pipeline (deferred to v0.2)

## Status

| Sprint | Focus | Status |
| --- | --- | --- |
| 1 | Foundation & scaffold | in progress |
| 2 | Bluetooth state & permissions | pending |
| 3 | Device discovery & connection | pending |
| 4 | ESC/POS core & Turkish charset | pending |
| 5 | Images & network printing | pending |
| 6 | iOS native, docs & release | pending |

## Usage

Not yet available on pub.dev. Usage examples will land with the `v0.1.0` release.

## License

See [LICENSE](LICENSE).

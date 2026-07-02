# printly

Thermal printer SDK for Flutter. Bluetooth Classic + BLE, ESC/POS receipts
(text, barcode, QR), Turkish charset (CP857), typed errors, and a built-in
permission flow — in one self-contained plugin with no opaque vendor SDKs.

> 🚧 **Under active development.** Targeting a `v0.1.0` release on pub.dev at
> the end of Sprint 6. Network (Ethernet/WiFi) printing and a raster
> (widget → image) pipeline are planned for the releases after that.

## Why another printer package?

Existing pub.dev options tend to wrap unclear vendor SDKs, go unmaintained,
or leave Bluetooth control to yet another package. printly is written from
scratch (Kotlin + Swift + Dart), owns the whole path from adapter state to
ESC/POS bytes, and treats cross-platform behavioural parity — same errors,
same states, same codes on Android and iOS — as a feature.

## Features

- Bluetooth **Classic (SPP)** and **BLE** scan/connect in a single plugin
  (network transport planned)
- Enum-based `BluetoothAdapterState` stream (not a bool)
- Per-device `ConnectionState` streams + `activeDeviceStream`
- Typed error model: sealed `PrintlyException` hierarchy with a
  cross-platform `PrintlyErrorCode` vocabulary — no string parsing
- Built-in permission flow (Android 12+ runtime permissions, iOS)
- Fluent ESC/POS `PrintJob` builder: text, feed, cut, divider, 7 barcode
  symbologies, QR with smart module sizing
- Turkish character support (CP857 primary, Windows-1254/ISO-8859-9
  fallbacks) with byte tables verified against the Unicode mappings
- Last-device persistence and opt-in auto-reconnect

## Quick start

```dart
import 'package:printly/printly.dart';

final printly = Printly.instance;

// 1. Permissions + scan
await printly.requestPermissions();
await printly.startScan();
printly.devicesStream.listen((devices) => /* show list */ ...);

// 2. Connect (Classic or BLE — the device knows its transport)
await printly.connect(device);

// 3. Build and print a receipt
final job = await printly.newJob(paperWidth: PrintlyPaperWidth.mm58);
job
  ..text('MAĞAZA', align: PrintlyTextAlign.center,
      style: PrintlyTextStyle.bold, charset: PrintlyCharset.turkish)
  ..divider()
  ..text('Teşekkürler', charset: PrintlyCharset.turkish)
  ..qr('https://example.com')
  ..barcode('PRINTLY', type: PrintlyBarcodeType.code128)
  ..feed(2)
  ..cut();
await printly.print(device, job);
```

Errors are typed — no string matching required:

```dart
try {
  await printly.connect(device);
} on PrintlyConnectionException catch (e) {
  if (e.code == PrintlyErrorCode.connectTimeout) {
    // retry / show "printer off?" hint
  }
} on PrintlyPermissionException {
  await printly.requestPermissions();
}
```

## Platform setup

### Android

No manifest changes needed — the plugin declares the Bluetooth permissions
(with the correct `maxSdkVersion` splits for Android 12+). Call
`Printly.instance.requestPermissions()` before scanning.

### iOS

1. Add the usage description to `ios/Runner/Info.plist`:

   ```xml
   <key>NSBluetoothAlwaysUsageDescription</key>
   <string>Used to find and print to your thermal printer.</string>
   ```

2. Enable the Bluetooth permission strategy in `ios/Podfile` —
   without this `requestPermissions()` always reports `permanentlyDenied`:

   ```ruby
   post_install do |installer|
     installer.pods_project.targets.each do |target|
       flutter_additional_ios_build_settings(target)
       target.build_configurations.each do |config|
         config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= [
           '$(inherited)',
           'PERMISSION_BLUETOOTH=1',
         ]
       end
     end
   end
   ```

3. iOS limitations: Bluetooth **Classic** requires MFi certification, so
   Classic printers are Android-only (`PrintlyErrorCode.classicRequiresMfi`);
   use the BLE transport on iOS. ESC/POS write on iOS lands in Sprint 6 —
   until then `print()` rejects with `PrintlyErrorCode.unsupportedPlatform`.

## Status

| Sprint | Focus | Status |
| --- | --- | --- |
| 1 | Foundation & scaffold | ✅ done |
| 2 | Bluetooth state & permissions | ✅ done |
| 3 | Device discovery & connection | ✅ done |
| 4 | ESC/POS core & Turkish charset | 🔨 in progress |
| 5 | Raster & network printing | pending |
| 6 | iOS write path, docs & release | pending |

## Tested hardware

| Printer | Transport | Paper | Notes |
| --- | --- | --- | --- |
| Cashino PTP-II | Classic (SPP) | 58 mm | Text/QR/barcode verified on Android 12. Ignores `ESC t` code-page selection → Turkish text on this device needs the raster pipeline (planned). |

## License

MIT — see [LICENSE](LICENSE).

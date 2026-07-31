# printly

[![pub package](https://img.shields.io/pub/v/printly.svg)](https://pub.dev/packages/printly)
[![CI](https://github.com/erenkirkil/printly/actions/workflows/ci.yml/badge.svg)](https://github.com/erenkirkil/printly/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Thermal printer SDK for Flutter. Bluetooth Classic + BLE, ESC/POS receipts
(text, barcode, QR), Turkish that prints on any printer, typed errors, and a
built-in permission flow — in one self-contained plugin with no opaque vendor
SDKs.

> **First release.** Verified end to end on real hardware, but on a single
> printer so far — see [Tested hardware](#tested-hardware). Network
> (Ethernet/WiFi) printing is planned for a later release and is deliberately
> absent from the API until it works.

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
- **Raster pipeline** — render text, images or a Flutter widget to dots and
  print them, so Turkish works even on printers that ignore code pages
- Last-device persistence and opt-in auto-reconnect

## Turkish on any printer

The usual way to print Turkish is to select a code page with `ESC t` and send
one byte per character. printly does that — and it is the cheaper path when it
works. But a good number of cheap printers **ignore `ESC t` entirely** and stay
on CP437 forever, and on those there is no byte you can send that produces `ğ`
or `İ`. (The Cashino PTP-II this package was developed against is one: every
page from 0 to 50 was swept, none took effect.)

So printly can draw the glyphs instead and send the dots:

```dart
final job = await printly.newJob(
  config: const PrintConfig(paperWidth: PrintlyPaperWidth.mm58),
);
await job.textRaster('PRINTLY MAĞAZA', align: PrintlyTextAlign.center, bold: true);
await job.textRaster('Ürün: Türk Kahvesi — ĞÜŞİÖÇ ğüşıöç');
await printly.print(device, job);
```

Text is shaped by the platform's own engine — the same one behind every `Text`
widget — so the printer's character set stops mattering.

Rendering is asynchronous while the printer commands are not, so for a longer
receipt render once and chain the results synchronously. A `PrintlyBitmap` is
immutable, which makes a logo rendered at startup free to reuse on every
receipt afterwards:

```dart
final logo = await PrintlyRaster.image(pngBytes, width: 384);
final header = await PrintlyRaster.text('MAĞAZA', width: 384, bold: true);

job..bitmap(logo)..bitmap(header)..text('...')..cut();
```

You can also print a widget you already have on screen:

```dart
final key = GlobalKey();
// somewhere in the tree, mounted and visible:
//   RepaintBoundary(key: key, child: SizedBox(width: 384, child: MyReceipt()))
await job.widget(key);
```

The boundary has to be **mounted and painted** — `Offstage` and
`Opacity(opacity: 0)` subtrees are never painted and cannot be captured, which
printly reports rather than letting the engine assert.

printly takes bytes, not URLs — fetching is your app's job, and keeping HTTP
out of the plugin keeps an `INTERNET` permission out of every app that depends
on it. The example shows the whole path with `dart:io` and no extra package.

**Watch the ink coverage, not just the size.** A broad area of solid black
draws more current than a cheap 5 V head can sustain, and a printer can shut
down mid-receipt without reporting anything your app can catch. Ordinary
receipt text sits near 8%; a logo pulled off the web routinely lands at 30–40%.
Keep artwork close to text-like coverage, prefer line art over photographs, and
leave `PrintlyDithering.floydSteinberg` on for images — scattered dots draw
less peak current than solid runs. `PrintlyBitmap.byteLength` and `heightMm`
let you check a job before sending it; printly does not block on your behalf,
because the real limit varies by printer and power supply and we will not
pretend to know yours.

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
   use the BLE transport on iOS. Most cheap 58 mm printers are dual-mode —
   they appear as Classic on Android and expose a BLE mode that iOS can see.

## Ecosystem readiness

Because printly is a *package*, it has to be ready for platform transitions
before the apps that depend on it:

- **Swift Package Manager** — the iOS sources ship with both a
  `Package.swift` (used automatically by Flutter 3.44+, where SPM is the
  default) and a `.podspec`, so CocoaPods-based apps keep working
  unchanged during the transition.
- **Android 16 KB page sizes** — printly's Android side is pure Kotlin and
  ships **no native (`.so`) binaries**, so the plugin itself is 16 KB
  compatible as-is (Google Play requires 16 KB support for new apps and
  updates targeting Android 15+ since November 1st, 2025). Your app's
  overall compatibility is determined by your Flutter version and other
  plugins; verify a release build with
  `zipalign -c -P 16 -v 4 app-release.apk`.

## Status

| Sprint | Focus | Status |
| --- | --- | --- |
| 1 | Foundation & scaffold | ✅ done |
| 2 | Bluetooth state & permissions | ✅ done |
| 3 | Device discovery & connection | ✅ done |
| 4 | ESC/POS core & Turkish charset | ✅ done |
| 5 | iOS Bluetooth print, SPM & 16 KB readiness | ✅ done |
| 6 | Raster pipeline, docs & release | ✅ done |

Network (Ethernet/WiFi) printing moved out of the `v0.1.0` scope and is
planned for a follow-up release.

## Tested hardware

| Printer | Transport | Paper | Notes |
| --- | --- | --- | --- |
| Cashino PTP-II | Classic (SPP) + BLE | 58 mm | Text/QR/barcode verified on Android 12; BLE print verified from iOS. **Ignores `ESC t` entirely** (pages 0–50 swept, none took effect) — Turkish works here through the raster path, verified on paper. Supports `GS v 0`; no cutter, and it answers the cut command by feeding blank paper. |

Verified on one printer so far. Support beyond this device class is the goal,
not a claim — a second BLE printer is the next thing on the hardware queue.

## License

MIT — see [LICENSE](LICENSE).

# printly

[![pub package](https://img.shields.io/pub/v/printly.svg)](https://pub.dev/packages/printly)
[![CI](https://github.com/erenkirkil/printly/actions/workflows/ci.yml/badge.svg)](https://github.com/erenkirkil/printly/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Thermal printer SDK for Flutter. Bluetooth Classic + BLE, ESC/POS receipts
(text, barcode, QR), Turkish that prints on any printer, typed errors, and a
built-in permission flow — in one self-contained plugin with no opaque vendor
SDKs.

> Verified end to end on real hardware, but on a single printer so far — see
> [Tested hardware](#tested-hardware). Network (Ethernet/WiFi) printing is
> planned for a later release and is deliberately absent from the API until
> it works.

## Why another printer package?

Existing pub.dev options tend to wrap unclear vendor SDKs, go unmaintained,
or leave Bluetooth control to yet another package. printly is written from
scratch (Kotlin + Swift + Dart), owns the whole path from adapter state to
ESC/POS bytes, and treats cross-platform behavioural parity — same errors,
same states, same codes on Android and iOS — as a feature.

## Features

- Bluetooth **Classic (SPP)** and **BLE** scan/connect in a single plugin
  (network transport planned)
- One `PrintlyDevice` per physical radio — `availableTransports` lists every
  transport it was seen on, and `connect(transport:)` picks which one to use
- Enum-based `BluetoothAdapterState` stream (not a bool), independent from
  runtime permission state (`checkPermissions()`/`requestPermissions()`)
- Per-device `ConnectionState` streams + `activeDeviceStream`
- Typed error model: sealed `PrintlyException` hierarchy with a
  cross-platform `PrintlyErrorCode` vocabulary — no string parsing
- Built-in permission flow (Android 12+ runtime permissions, iOS) plus
  `requestEnableBluetooth()` to prompt the user to turn the radio on
- Fluent ESC/POS `PrintJob` builder: text, feed, cut, divider, 7 barcode
  symbologies, QR with smart module sizing, and an opt-in `unmappable`
  policy for sanitizing payloads a QR/barcode symbology can't encode
- Turkish character support (CP857 primary, Windows-1254/ISO-8859-9
  fallbacks) with byte tables verified against the Unicode mappings, plus a
  standalone `TurkishCodePage.toLatin1()` sanitizer
- **Raster pipeline** — render text, images or a Flutter widget to dots and
  print them, so Turkish works even on printers that ignore code pages
- Screen-scoped `newScanSession()` handles and a `classicFirst` scan
  strategy alongside the process-lifetime `devicesStream`
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

### Sanitizing QR & barcode payloads

`PrintJob.qr()` and `PrintJob.barcode()` reject input they can't encode —
`qr()` requires Latin-1 (so `ş ı ğ İ` and typographic punctuation like `₺`
or smart quotes throw by default), and `barcode()`'s CODE128/CODE39 have
their own narrow charsets. That default (`PrintlyUnmappable.throwError`)
is unchanged — silent data loss inside a scannable code stays strictly
opt-in. Pass `unmappable: PrintlyUnmappable.transliterate` to convert
readable equivalents (Turkish letters, smart quotes, dashes) via
`TurkishCodePage.toLatin1()` first and substitute whatever's left, or
`PrintlyUnmappable.replace` to substitute everything unrepresentable
outright:

```dart
job.qr(
  '₺150 — “Kahve” siparişi',
  unmappable: PrintlyUnmappable.transliterate,
);
// -> '?150 - "Kahve" siparisi' — the em dash and curly quotes transliterate,
// "ş" becomes "s", but "₺" has no readable Latin-1 equivalent and falls to
// the replacement byte ('?' by default; pass `replacement:` to change it).
```

`TurkishCodePage.toLatin1()` is also public on its own, for sanitizing any
string headed somewhere Latin-1-only (a field, a log, a receipt line) without
going through a `PrintJob` call.

## Scanning

`startScan()` defaults to a 10 s timeout (`kDefaultScanTimeout`) and a
platform-appropriate transport set — `{classic, ble}` on Android, `{ble}` on
iOS (it has no public Classic API). Override either per call, or set
`Printly.instance.defaultScanTimeout` once for every call that omits
`timeout`:

```dart
await printly.startScan(); // 10 s, platform-default transports
await printly.startScan(timeout: const Duration(seconds: 20));
printly.defaultScanTimeout = const Duration(seconds: 20); // app-wide default
```

**The bonded-seed trap.** On Android, Classic discovery seeds `devicesStream`
from the OS bond cache *before* any inquiry result arrives, so a printer you
paired months ago (and that may not even be powered on) can appear
immediately. `PrintlyDevice.seenInScan` is `false` for those seed-only
entries — connecting to one can still end in a timeout. Pass
`includeBonded: false` to exclude bonded seeds from `devicesStream` entirely
until an inquiry actually confirms them, or check `seenInScan` yourself
before offering a "connect" affordance on an unconfirmed entry.

**The location-service trap (Android 6–11).** On Android API < 31, Bluetooth
discovery is also gated on the OS location *service* (not just the location
*permission*) — granting the permission is not enough. With the service off,
scans return zero results and the platform raises no error, so the app has no
signal to explain the empty list. printly detects this and rejects
`startScan()` with `PrintlyScanException(PrintlyErrorCode.locationServicesDisabled)`
instead. Check ahead of time with `isLocationServiceEnabled()` and route the
user to the right screen with `openLocationSettings()`:

```dart
if (!await printly.isLocationServiceEnabled()) {
  await printly.openLocationSettings();
  return;
}
await printly.startScan();
```

This does not apply to Android 12+ (`neverForLocation` Bluetooth permissions
drop the location-service requirement) or to iOS — on both,
`isLocationServiceEnabled()` always returns `true` and `openLocationSettings()`
is a no-op that returns `false`.

**Classic printers and the scan timeout.** Android's Classic inquiry cycle
takes ~12.8 s end to end; the 10 s default window can cut it short, so a
Classic-only printer that answers late in the cycle may be missed. In
Classic-heavy environments, give the inquiry room to finish:

```dart
printly.defaultScanTimeout = const Duration(seconds: 15);
```

`ScanStrategy.classicFirst` (opt-in, experimental) scans Classic first on
Android and falls back to a single BLE round only if nothing named answered —
the idea being that a Classic inquiry saturates the radio and a parallel scan
can miss BLE-only printers under contention. **Field data has not yet shown
round 1 confirming a device** (see the timeout note above — the round-1
window structurally undercuts the inquiry cycle), so prefer the default
`parallel` strategy unless you have measured a benefit on your hardware;
reports welcome via the "New Printer Test" issue template. It degrades
silently to a single BLE round on iOS.

For screen-scoped scanning (e.g. a "pick a printer" dialog), use
`newScanSession()` instead of the process-lifetime `devicesStream`/
`isScanningStream` — a session's `devices`/`isScanning` streams are seeded
empty/`false` and never replay a previous screen's stale state:

```dart
class _PrinterPickerState extends State<PrinterPicker> {
  late final PrintlyScanSession _session = printly.newScanSession();

  @override
  void initState() {
    super.initState();
    _session.start();
  }

  @override
  void dispose() {
    _session.dispose(); // not just stop() — see the API doc
    super.dispose();
  }

  // build(): StreamBuilder on _session.devices / _session.isScanning
}
```

### Connecting without scanning (known address)

Scanning is a discovery affordance, not a requirement. If you already know
the printer's MAC address — a fixed fleet, a QR label on the device, an
address stored by your own app — construct the `PrintlyDevice` yourself and
connect directly:

```dart
const printer = PrintlyDevice(
  address: 'DC:0D:30:12:34:56',
  availableTransports: {ConnectionType.classic}, // or {ConnectionType.ble}
);
await printly.connect(printer);
```

This skips the scan entirely: no location-service gate, no 10-second wait,
no list to pick from. It also composes into a "remember my printer" flow —
persist `address` and the transport with whatever storage your app already
uses, rebuild the device on startup, connect.

**iOS caveat:** on iOS the `address` is not a MAC — CoreBluetooth hides MAC
addresses and identifies peripherals by a per-phone UUID that can only be
learned from a scan. Direct-address connect is therefore an Android
technique; on iOS, store the UUID your app observed in a previous scan of
that same phone, or scan again.

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

## Migrating from 0.1.x

`0.2.0` merges each physical radio into a single `PrintlyDevice` and moves
transport selection into `connect()`:

- `device.type` is gone — a dual-mode printer used to show up twice (once as
  Classic, once as BLE); it now shows up **once**, with
  `device.availableTransports` listing every transport it was seen on.
  Replace `device.type` reads with `device.availableTransports`, and pick a
  specific one at connect time: `printly.connect(device, transport:
  ConnectionType.ble)`. Leaving `transport` out uses the platform default —
  Classic on Android for a dual-mode radio (the field-proven RFCOMM path),
  BLE always on iOS.
- Persisted last-connected devices from 0.1.x are migrated automatically —
  `loadLastConnectedDevice()`/`reconnectLastDevice()` still work with no
  action needed.
- Any 0.1.x call site that built a `const PrintlyDevice(...)` no longer
  compiles: `availableTransports` is validated with a runtime assert
  (must be non-empty), which `const` evaluation can't satisfy. Drop the
  `const`.
- `adapterState` used to fold missing Android runtime permissions into
  `BluetoothAdapterState.unauthorized` and then freeze there (Android never
  re-broadcasts on a permission change). It now reports the radio's actual
  state only. Gate permission-dependent UI on `checkPermissions()` instead
  of watching `adapterState` for `unauthorized`.
- `kDefaultScanTimeout` dropped from 30 s to 10 s, and the implicit
  `startScan()` transport set is now platform-aware (`{ble}` on iOS) instead
  of always `{classic, ble}`. Pass an explicit `timeout`/`types`, or set
  `Printly.instance.defaultScanTimeout`, to keep the old behaviour.

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

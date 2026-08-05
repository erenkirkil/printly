## 0.2.0

### Fixed

- **Android BLE:** `requestMtu()` and `discoverServices()` were issued
  back-to-back, racing on the single-operation GATT queue; on some stacks
  (observed on Android 11) discovery was silently dropped and every BLE
  connect died on the 10 s timeout. Discovery is now chained after the MTU
  exchange settles, with a 1.5 s fallback so a missing `onMtuChanged` can
  never wedge the connect.

### Added

- `TurkishCodePage.toLatin1()` — public sanitization helper that makes any
  string Latin-1 safe, transliterating Turkish letters and typographic
  punctuation to readable ASCII.
- `PrintJob.qr()` now accepts `unmappable: PrintlyUnmappable` (default
  `throwError`, unchanged) and `replacement`, so field input containing
  `₺`, smart quotes or em dashes can print a sanitized QR instead of
  throwing.

## 0.1.0 — 2026-07-31

First release. Bluetooth thermal printing for Flutter, written from scratch in
Kotlin, Swift and Dart, with Turkish text that works even on printers that
cannot be told about code pages.

### Bluetooth

- Classic (SPP) and BLE in one plugin — Classic on Android, BLE on both
  platforms. Network transport is not implemented and is not advertised.
- `BluetoothAdapterState` as a six-value enum stream, not a bool.
- Scanning with de-duplication by transport + address, 250 ms emission
  coalescing, timeouts, and a separate error stream for mid-scan failures.
- Per-device `ConnectionState` streams plus `activeDeviceStream`. `connected`
  means *ready to print* — services discovered and a writable characteristic
  resolved — not merely linked.
- Runtime permissions (Android 12+ and legacy, iOS) behind
  `PrintlyPermissionStatus`, with no third-party permission type in the API.
- Last-device persistence and opt-in auto-reconnect.

### Printing

- Fluent `PrintJob` builder: text, feed, cut, divider, raw bytes, seven barcode
  symbologies, and QR with automatic module sizing from payload length, error
  level and paper width.
- Turkish through code pages: CP857 primary, Windows-1254 and ISO-8859-9
  fallbacks, byte tables derived from the Unicode Consortium mappings and
  cross-checked against CPython and libiconv.
- 58 mm and 80 mm paper, with characters-per-line and dot width derived from
  the setting rather than hardcoded at call sites.

### Raster — Turkish on any printer

- `PrintlyRaster.text()` draws glyphs with the platform's own text engine and
  sends dots, so the printer's character set stops mattering. Some printers
  ignore `ESC t` outright; on those this is the only way to print `ğ` or `İ`.
- `PrintlyRaster.image()` decodes PNG/JPEG/WebP and fits it to the paper.
- `PrintlyRaster.widgetKey()` captures a mounted `RepaintBoundary`.
- `PrintlyBitmap` is immutable, so a logo rendered once is free to reuse; it
  also keeps `PrintJob.bitmap()` synchronous and chainable.
- Floyd-Steinberg or plain threshold dithering, emitted as `GS v 0` bands.

### Errors

- Sealed `PrintlyException` hierarchy over a `PrintlyErrorCode` vocabulary
  shared byte-for-byte between Dart, Kotlin and Swift. A raw `PlatformException`
  never reaches your code and there is nothing to string-match.

### Platform

- Android: minSdk 24, 16 KB page-size compatible (pure Kotlin, no `.so`).
- iOS: 13.0+, shipped for both CocoaPods and Swift Package Manager.
- Flutter `>=3.35.3` — the first release bundling the Dart 3.9.2 this package
  requires. 3.35.0 through 3.35.2 ship Dart 3.9.0 and were previously claimed
  in error, which would have met anyone on them with a resolution failure
  rather than a clear "unsupported". CI now builds against both this floor and
  current stable, which is how the mismatch surfaced.

### Known limits

- Verified on one printer (Cashino PTP-II). Broader support is the goal, not a
  claim.
- Ink coverage is a hardware limit: a broad solid-black area can draw more
  current than a cheap 5 V head sustains and the printer may cut out with no
  catchable error. printly reports size and coverage but does not block.
- Bluetooth Classic gives a whole job a single 10-second write budget on
  Android; a very long raster receipt can exceed it.

---

## Development log

The sections below record how the package was built, sprint by sprint. They
are kept for provenance — every entry above is already covered by one of them.

### Sprint 6 — Raster pipeline (2026-07-31)

Turkish text no longer depends on the printer's character set.

#### Added

- **`PrintlyRaster`** — renders to printable dots:
  - `text()` shapes a string with the platform text engine (wrapping,
    alignment, weight) — the path that makes Turkish work on printers that
    ignore `ESC t`.
  - `image()` decodes PNG/JPEG/WebP and fits it to the paper. `width` is a
    ceiling, not a stretch: a narrow image keeps its size and the printer
    centres it rather than being upscaled into a blur.
  - `repaintBoundary()` / `widgetKey()` capture a mounted, painted
    `RepaintBoundary`. A widget is not accepted directly because Flutter
    offers no supported way to render a detached tree — an API that took one
    would be promising what it cannot do. `Offstage` and zero-opacity
    subtrees are rejected with an explanation instead of an engine assert.
- **`PrintlyBitmap`** — an immutable one-bit image, and the seam between the
  asynchronous rendering half and the synchronous command half. Rendering a
  logo once and stamping it onto every receipt costs nothing after the first.
  `toRgba()` expands it back to pixels so a preview can show exactly what the
  head will burn.
- **`PrintlyDithering`** — Floyd-Steinberg (a two-row error buffer rather than
  a full plane: 1.5 KB instead of 1.5 MB for a receipt) or a plain threshold.
  Two values, not three: a `none` mode would be byte-identical to `threshold`.
- **`PrintJob.bitmap()`** appends a rendered bitmap synchronously, so it still
  chains. Alignment goes through the generator's style cache — emitted as raw
  bytes it would leave the cache stale and the next `text()` would print
  misaligned. `textRaster()`, `image()` and `widget()` are awaitable sugar over
  it, typed so a mistaken cascade is a compile error rather than a scrambled
  receipt.
- **`PrintConfig.rasterBandHeight`** (default 64 rows). Tall images are split
  into `GS v 0` bands, each about 3 KB at 58 mm, staying under 256 rows so the
  command's high height byte is always zero — firmware that ignores that byte
  is a known hazard.

#### Notes

- The wrapped library's own raster path is not used. For any width that is not
  already a multiple of 8 it replaces the pixel data with a zero-filled
  fixed-length list and then calls `insertAll` on it, so it throws before it
  can print — and derives its header from the unaligned width regardless.
  printly emits `GS v 0` itself and rounds widths **down** to a multiple of 8,
  because rounding up would overflow the head and make the printer wrap.
- Transparent pixels composite to white, not black. `dart:ui` returns
  premultiplied alpha, so reading the colour channels of a transparent canvas
  naively yields black — and a receipt-sized black bitmap would burn a roll.
- Text uses a lighter cutoff (176) than images (128). A font rasteriser
  antialiases, and at the neutral cutoff only the one-dot core of each stroke
  burns; thermal heads render isolated dots weakly, so ordinary weights came
  out washed out while bold looked fine. Measured on paper.
- Verified end to end on a Cashino PTP-II — the printer that ignores `ESC t`
  and so could not print Turkish at all before this.

### Sprint 5 — iOS Bluetooth print & platform readiness (2026-07-02)

#### Added

- **iOS ESC/POS printing over BLE.** `print()`/`write()` now works on iOS:
  after the link comes up, printly discovers services, resolves the write
  characteristic (same preference order as Android: `FF02`,
  `49535343-8841-…`, `FFE1`, then any writable), and streams the job in
  single-ATT-packet chunks bounded by a 5 s per-chunk watchdog. The
  `connected` state now means *ready-to-print* on iOS exactly as it does on
  Android — it is emitted only after the write characteristic is resolved,
  and the connect timeout covers service discovery too. Error vocabulary is
  byte-identical with Android (`not_connected`, `not_ready`, `write_busy`,
  `write_timeout`, `write_failed`).
- **Swift Package Manager support.** iOS sources moved to the SPM layout
  (`ios/printly/Sources/printly/`) with a `Package.swift`; Flutter 3.44+
  resolves the plugin via SPM automatically. The `.podspec` still points at
  the same sources, so CocoaPods apps are unaffected.
- **Android 16 KB page-size compatibility** documented: the Android side is
  pure Kotlin with no bundled native binaries, so the plugin is 16 KB
  compatible as-is; README explains what consumers need to check.

#### Changed

- Network (Ethernet/WiFi) printing moved out of the `v0.1.0` scope to a
  post-v1 release; the raster pipeline moved to Sprint 6 (still pre-v1).
  `PrintlyDevice.network(...)` and `ConnectionType.network` remain in the
  API and keep rejecting with `network_not_supported`.

### Hardening & deep-review fixes (2026-07-02)

A six-dimension adversarially-verified code review (69 findings) was applied
across all three layers, verified end-to-end (`flutter analyze` clean,
151 tests, Android APK + iOS build green).

#### Fixed

- **Persistence:** the last-connected device is now persisted on every
  successful `connect()` (previously only after a store-touching API call),
  and a persisted auto-reconnect flag re-arms its adapter listener on the
  next launch — both "remember my printer" features actually work now.
- **Dart races:** `stopScan(); startScan();` (the natural rescan gesture) is
  queued instead of silently swallowed; a stale `disconnected` event from a
  torn-down link no longer rejects a fresh `connect()` to the same device.
- **QR:** payloads over 252 bytes emitted a corrupt `GS ( k` store command
  (the wrapped library hardcodes `pH=0`); printly now emits the QR function
  sequence itself with correct two-byte length math. Payloads beyond the QR
  byte-mode maximum (2953) throw `ArgumentError`.
- **Barcodes:** literal `{` in CODE128 payloads is escaped (`{{`) and
  caller-supplied `{A`/`{B`/`{C` selectors are honoured; module width is
  clamped to the spec range 2–6 and emitted on every barcode so one
  barcode's width never leaks into the next.
- **Failed-future caching:** a failed `CapabilityProfile.load()` or
  `LastDeviceStore.open()` no longer bricks `newJob()`/persistence for the
  rest of the session — failures are evicted and retried.
- **Android:** scanning with Bluetooth off now rejects with
  `bluetooth_not_powered_on` (was a silent, empty 30 s scan); GATT callbacks
  are main-thread-confined (removes watchdog/retry data races); a
  `connectGatt` early-failure race that could leak a GATT client slot is
  closed and a `null` return fails fast; user-initiated disconnects no
  longer terminate in `error`; `connect()` during teardown rejects with
  `disconnect_in_progress` instead of re-emitting a false `connected`;
  Classic `write()` is gated on connection state (its watchdog could kill
  an in-flight connect); Classic connect-timeout reason aligned to
  `connect_timeout`; `write_timeout`/`disconnected` now reach Dart as their
  own error codes.
- **iOS:** the first `startScan()`/`connect()` after launch no longer fails
  deterministically (`CBCentralManager` operations queue until the first
  `didUpdateState`); connect-timeout work items are cancelled on terminal
  states (a stale timeout could abort a later attempt to the same
  peripheral); duplicate `connect()` re-emits the effective state so a
  hot-restarted Dart side rehydrates (Android parity); `disconnect()`
  during a pending connect reaps synchronously and established links get a
  4 s fallback reaper; `detachFromEngine` implemented (native resources no
  longer outlive the engine); the private `App-Prefs:` URL scheme removed
  (App Store 2.5.1 risk — app settings page is opened instead);
  `.unauthorized` surfaces as `permission_denied` (was a misleading
  `bluetooth_not_powered_on`).

#### Added

- **Typed error model:** sealed `PrintlyException` hierarchy
  (`PrintlyScanException`, `PrintlyConnectionException` with a
  `TimeoutException`-compatible timeout subtype, `PrintlyWriteException`,
  `PrintlyPermissionException`, `PrintlyUnsupportedException`) carrying a
  cross-platform `PrintlyErrorCode`; `PlatformException`s are mapped at the
  method channel, so consumers switch on codes instead of parsing strings.
- `PrintlyPermissionStatus` — printly's own enum; `permission_handler`'s
  `PermissionStatus` no longer leaks into (or is re-exported from) the
  public API.
- `Printly.scanErrorsStream` — mid-scan native failures (Bluetooth toggled
  off, scan-failed callbacks) are surfaced instead of looking like a normal
  timeout stop.
- **CP437 table** for `PrintlyCharset.latin`: é ü ç ö £ ° and the rest of
  the CP437 repertoire now print instead of `?` (only ğ Ğ ı İ ş Ş remain
  unrepresentable on that page).
- **Android BLE MTU negotiation** (`requestMtu(517)`, chunking at MTU−3,
  `WRITE_TYPE_NO_RESPONSE` preferred when supported) — the throughput
  prerequisite for the upcoming raster sprint.
- Wire-protocol strings single-sourced per platform (`WireProtocol` in
  Dart, `WireCodes` in Kotlin and Swift) — channel/method/key/error strings
  can no longer drift silently at individual call sites.
- iOS `PERMISSION_BLUETOOTH=1` Podfile requirement documented in the README
  and applied to the example app (without it `requestPermissions()` always
  reported `permanentlyDenied` on iOS).
- Exhaustive code-page table tests (every defined byte of CP437/CP857/
  Windows-1254/ISO-8859-9 round-trips), a golden receipt byte-stream test
  pinning the wire format against dependency upgrades, GS `!` size-operand
  and style-reset tests, facade persistence/auto-reconnect regression
  tests, and typed-error mapping tests. 151 tests total.

#### Changed

- `Printly.connect()` fails fast with `PrintlyUnsupportedException` for
  `ConnectionType.network` devices until the network transport lands.
- `requestPermissions()` returns `PrintlyPermissionStatus`.
- The speculative `wireCode`/`fromWireCode` API was removed from the nine
  print-layer enums (nothing crosses the wire there; the connection/adapter
  enums keep theirs).
- Unused `image`, `mockito`, and `build_runner` dependencies removed; the
  Flutter lower bound corrected to `>=3.35.0` to match `sdk: ^3.9.2`.
- LICENSE set to MIT. CI now compiles both native layers (example APK +
  iOS build), runs the example tests, and the publish dry-run gate is no
  longer advisory (`continue-on-error` removed).
- `QrSizing` exported alongside `TurkishCodePage` as stable utilities.
- Docs honesty pass: pubspec/podspec/README no longer advertise
  unimplemented Ethernet/WiFi; `ConnectionState.reconnecting` documented as
  reserved (never emitted today); barcode GS k function A/B docs corrected;
  `raw()` documents its style-cache caveat.

### Sprint 4 — ESC/POS core & Turkish charset

- Print-layer enums (all `Printly`-prefixed to avoid clashes with `dart:ui`/Material): `PrintlyPaperWidth` (58 mm = 384 dots, 80 mm = 576 dots), `PrintlyTextAlign`, `PrintlyTextStyle`, `PrintlyTextSize`, `PrintlyCutMode`, `PrintlyBarcodeType`, `PrintlyCharset`, `PrintlyQrErrorLevel`, `PrintlyHriPosition`.
- `TurkishCodePage.encode()` — a dedicated CP857 (primary) / Windows-1254 / ISO-8859-9 encoder. The byte tables were derived from the Unicode Consortium mappings and cross-checked against the CPython `cp857`/`cp1254` codecs and libiconv; they correct the inaccurate example table in the roadmap (e.g. `ğ`→`0xA7`, `ş`→`0x9F`, `Ş`→`0x9E`). `ESC t` selectors corrected to CP857 = 13 and WPC1254 = 48.
- `PrintConfig` and the fluent `PrintJob` builder (`text`, `feed`, `cut`, `divider`, `raw`, `barcode`, `qr`), layered on `esc_pos_utils_plus` for command framing while overriding only the Turkish text encoding via `textEncoded`.
- 1-D barcodes for 7 symbologies (EAN-13/8, UPC-A, CODE39, CODE128, ITF, CODABAR) with automatic CODE128 `{B` code-set prefixing and HRI controls.
- Smart QR sizing (`QrSizing`): estimates the symbol version from payload length + error level and picks the largest module dot size that fits the paper, with an optional `maxModuleSize` cap.
- `Printly.instance.newJob(...)` and `print(device, job)`, plus a new `write({device, bytes})` platform method.
- Android native write path: RFCOMM `OutputStream` writes for Classic, and GATT service discovery + ack-gated chunked characteristic writes (API 33+ and legacy paths) for BLE. iOS `write` rejects with `unsupported_platform` pending Sprint 6.
- Example app: 58/80 mm paper-width selector and a Turkish test-receipt button (text + QR + barcode).

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

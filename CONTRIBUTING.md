# Contributing to printly

Thanks for considering a contribution! This document explains how the project
is developed, what a change must satisfy before it can merge, and the one rule
that is absolutely non-negotiable.

## The one non-negotiable rule: wire-protocol sync

The strings and integers that cross the platform channel live in **three
hand-synchronized files**:

| Language | File |
| --- | --- |
| Dart | `lib/src/platform/wire_protocol.dart` |
| Kotlin | `android/src/main/kotlin/com/erenkirkil/printly/util/WireCodes.kt` |
| Swift | `ios/printly/Sources/printly/WireCodes.swift` |

**Never inline a channel name, method name, payload key, or error string** —
always reference these files, and when you add or change a value, change **all
three in the same commit**. `test/platform/wire_parity_test.dart` parses the
Kotlin and Swift sources and fails CI on any drift, so you will be caught —
but fix it before CI has to tell you. The integer tables are marked "Do not
reorder"; they mean it.

Two related rules from the same family:

- **Never leak a raw `PlatformException`.** Every error surfaces as a sealed
  `PrintlyException` subtype with a `PrintlyErrorCode` (see the `_mapErrors`
  pattern in `printly_method_channel.dart`).
- **Never expose a third-party type in the public API.** `permission_handler`
  and similar dependencies stay behind printly-owned types.

## Development setup

```bash
git clone https://github.com/erenkirkil/printly
cd printly
flutter pub get
flutter test          # must be green
flutter analyze       # must report zero issues (strict modes are on)
```

The example app under `example/` runs on a real device; Bluetooth does not
work in simulators/emulators, so behavioral verification ultimately happens on
hardware (see "Testing a printer" below).

## Quality gates

Every PR must pass all of these locally before review — they are the same
gates CI runs:

```bash
dart format --set-exit-if-changed .   # formatting
flutter analyze                       # zero violations, including public_member_api_docs
flutter test                          # root suite
cd example && flutter test            # example widget tests
flutter pub publish --dry-run         # package sanity
```

Style expectations beyond the linter:

- Public types are `Printly`-prefixed; public constants are `k`-prefixed and
  exported selectively via the `lib/printly.dart` barrel's `show` clause.
- Doc comments are **English** and explain *why* — which bug a guard prevents,
  which field measurement motivated a default — not just what the code does.
- Tests use hand-written fakes with `MockPlatformInterfaceMixin` (no mockito,
  no build_runner); the `test/` tree mirrors `lib/src/`.
- Commit messages are English, conventional format:
  `fix(scan): drop results arriving after stopScan completed`.

## Testing a printer we haven't tested

printly aims at **generic ESC/POS thermal printer support** — every new
device class widens the verified matrix in the README. You can help without
writing a line of code:

1. Open an issue with the **New Printer Test** template.
2. Run the example app against your printer and fill in what worked: scan,
   connect (which transport), text, Turkish text, QR, barcode, raster.
3. Include the device model, its advertised name, and anything odd — printers
   that ignore `ESC t`, feed instead of cutting, or brown-out on dense raster
   are all findings we document by name.

Quirky firmware is not noise here — it is the core of what this package
absorbs so app developers don't have to. A report that "X prints garbage" with
a photo of the receipt is a genuinely valuable contribution.

## Pull requests

- Open an issue first for anything beyond a trivial fix, so scope can be
  agreed before you invest time.
- One concern per PR; behavior changes come with tests that pin them.
- Breaking changes need a CHANGELOG entry under `## Unreleased` with a
  migration note — this package is published on pub.dev and consumers upgrade
  on semver trust.
- If your change touches scanning, connection, or the write path, say in the
  PR description whether you verified on hardware and which device; the
  maintainer runs a hardware round before each release either way.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). Be kind.

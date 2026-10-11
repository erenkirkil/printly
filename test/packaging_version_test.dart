import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Packaging-manifest version parity.
///
/// The published version lives in `pubspec.yaml`, but CocoaPods reads its own
/// copy from `ios/printly.podspec`. Those two drifted in 0.3.0 — the podspec
/// was left at `0.2.0` — and nothing caught it, because `pod lib lint` does
/// not compare the two and the release checklist only bumped the pubspec.
///
/// The drift is not cosmetic. A `Podfile.lock` `SPEC CHECKSUMS` entry is the
/// hash of the *podspec file*, not of the sources it points at. An unchanged
/// podspec means an unchanged checksum, so CocoaPods sees no reason to
/// regenerate the Pods project even when the Swift sources underneath have
/// changed. In 0.3.0 the right code still compiled, but only because the file
/// *set* happened to be identical; the next release that adds or removes a
/// Swift file would leave consumers building a stale source list, silently and
/// without an error.
///
/// SPM needs no equivalent check: `Package.swift` carries no version — the
/// package version comes from the git tag.
void main() {
  test('podspec version matches pubspec version', () {
    final File pubspecFile = File('pubspec.yaml');
    final File podspecFile = File('ios/printly.podspec');
    expect(
      pubspecFile.existsSync(),
      isTrue,
      reason: 'expected to run from the package root: ${pubspecFile.path}',
    );
    expect(podspecFile.existsSync(), isTrue, reason: podspecFile.path);

    final RegExpMatch? pubspecMatch = RegExp(
      r'''^version:\s*(\S+)\s*$''',
      multiLine: true,
    ).firstMatch(pubspecFile.readAsStringSync());
    expect(
      pubspecMatch,
      isNotNull,
      reason: 'no top-level `version:` key in ${pubspecFile.path}',
    );

    final RegExpMatch? podspecMatch = RegExp(
      r'''^\s*s\.version\s*=\s*['"]([^'"]+)['"]''',
      multiLine: true,
    ).firstMatch(podspecFile.readAsStringSync());
    expect(
      podspecMatch,
      isNotNull,
      reason: 'no `s.version` assignment in ${podspecFile.path}',
    );

    expect(
      podspecMatch![1],
      pubspecMatch![1],
      reason:
          'ios/printly.podspec is out of sync with pubspec.yaml. Bump '
          '`s.version` in the podspec whenever the pubspec version changes — '
          'CocoaPods reports the podspec value to consumers and keys its '
          'change detection on it.',
    );
  });
}

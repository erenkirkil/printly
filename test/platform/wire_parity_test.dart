import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';
import 'package:printly/src/platform/wire_protocol.dart';

/// Cross-language wire-protocol parity.
///
/// The wire vocabulary lives in three hand-synchronized files — Dart
/// `WireProtocol`, Kotlin `WireCodes.kt`, Swift `WireCodes.swift` — and the
/// project rule says every new value must touch all three. Until now nothing
/// enforced that: a constant added or edited in one language would only
/// surface as a runtime protocol mismatch on real hardware. These tests parse
/// the two native sources and assert name/value agreement with the Dart side,
/// so drift fails CI instead.
void main() {
  final File kotlinFile = File(
    'android/src/main/kotlin/com/erenkirkil/printly/util/WireCodes.kt',
  );
  final File swiftFile = File('ios/printly/Sources/printly/WireCodes.swift');

  late final _ParsedWire kotlin;
  late final _ParsedWire swift;

  setUpAll(() {
    expect(
      kotlinFile.existsSync(),
      isTrue,
      reason: 'expected to run from the package root: ${kotlinFile.path}',
    );
    expect(swiftFile.existsSync(), isTrue, reason: swiftFile.path);
    kotlin = _ParsedWire.parse(kotlinFile.readAsStringSync());
    swift = _ParsedWire.parse(swiftFile.readAsStringSync());
  });

  // The Dart-side string vocabulary, referenced (not retyped) so a rename on
  // the Dart side automatically updates the expectation.
  const Set<String> dartChannels = <String>{
    WireProtocol.methodChannel,
    WireProtocol.adapterStateChannel,
    WireProtocol.scanResultsChannel,
    WireProtocol.connectionEventsChannel,
  };
  const Set<String> dartMethods = <String>{
    WireProtocol.mGetPlatformVersion,
    WireProtocol.mGetAndroidSdkInt,
    WireProtocol.mOpenBluetoothSettings,
    WireProtocol.mRequestEnableBluetooth,
    WireProtocol.mStartScan,
    WireProtocol.mStopScan,
    WireProtocol.mConnect,
    WireProtocol.mDisconnect,
    WireProtocol.mWrite,
    WireProtocol.mIsLocationServiceEnabled,
    WireProtocol.mOpenLocationSettings,
  };
  const Set<String> dartKeys = <String>{
    WireProtocol.keyDevice,
    WireProtocol.keyTimeoutMs,
    WireProtocol.keyTypes,
    WireProtocol.keyBytes,
    WireProtocol.keyAddress,
    WireProtocol.keyType,
    WireProtocol.keyName,
    WireProtocol.keyRssi,
    WireProtocol.keyIsBonded,
    WireProtocol.keyState,
    WireProtocol.keyFailureReason,
    WireProtocol.keySeenInScan,
  };

  group('string constants (channels, methods, payload keys)', () {
    test('Kotlin matches Dart exactly, per section', () {
      expect(kotlin.strings['Channels'], dartChannels);
      expect(kotlin.strings['Methods'], dartMethods);
      expect(kotlin.strings['Keys'], dartKeys);
    });

    test('Swift matches Dart exactly, per section', () {
      expect(swift.strings['Channels'], dartChannels);
      expect(swift.strings['Methods'], dartMethods);
      expect(swift.strings['Keys'], dartKeys);
    });
  });

  group('integer wire codes', () {
    // Expected name → value pairs derived from the Dart enums, so the enums
    // stay the single source of truth for the expectation too.
    final Map<String, int> expected = <String, int>{
      'typeClassic': ConnectionType.classic.wireCode,
      'typeBle': ConnectionType.ble.wireCode,
      'typeNetwork': ConnectionType.network.wireCode,
      for (final ConnectionState s in ConnectionState.values)
        'state${_capitalize(s.name)}': s.wireCode,
    };

    test('Kotlin and Swift agree with the Dart enums', () {
      for (final MapEntry<String, int> e in expected.entries) {
        expect(kotlin.ints[e.key], e.value, reason: 'Kotlin ${e.key}');
        expect(swift.ints[e.key], e.value, reason: 'Swift ${e.key}');
      }
    });

    test('adapter codes round-trip through BluetoothAdapterState.fromCode', () {
      const Map<String, BluetoothAdapterState> adapterNames =
          <String, BluetoothAdapterState>{
            'adapterUnknown': BluetoothAdapterState.unknown,
            'adapterResetting': BluetoothAdapterState.resetting,
            'adapterUnsupported': BluetoothAdapterState.unsupported,
            'adapterUnauthorized': BluetoothAdapterState.unauthorized,
            'adapterPoweredOff': BluetoothAdapterState.poweredOff,
            'adapterPoweredOn': BluetoothAdapterState.poweredOn,
          };
      for (final MapEntry<String, BluetoothAdapterState> e
          in adapterNames.entries) {
        expect(
          BluetoothAdapterState.fromCode(kotlin.ints[e.key]!),
          e.value,
          reason: 'Kotlin ${e.key}',
        );
        expect(
          BluetoothAdapterState.fromCode(swift.ints[e.key]!),
          e.value,
          reason: 'Swift ${e.key}',
        );
      }
      // Both sides define exactly the same integer constants overall — no
      // extra or missing codes hiding outside the named expectations.
      expect(kotlin.ints, swift.ints);
    });
  });

  group('failure-reason strings', () {
    // Channel-crossing strings that are deliberately NOT part of the shared
    // PrintlyErrorCode vocabulary (native-internal diagnostics carried in
    // messages, mapped to broader codes on the Dart side).
    const Set<String> nativeInternal = <String>{
      'invalid_args',
      'invalid_payload',
      'invalid_address',
      'unsupported_transport',
      'service_discovery_failed',
      'no_writable_characteristic',
    };

    test('every native reason is either a PrintlyErrorCode wireName or a '
        'documented native-internal string', () {
      for (final _ParsedWire side in <_ParsedWire>[kotlin, swift]) {
        for (final String reason in side.strings['Reasons'] ?? <String>{}) {
          final bool mapped =
              PrintlyErrorCode.fromWireName(reason) != PrintlyErrorCode.unknown;
          expect(
            mapped || nativeInternal.contains(reason),
            isTrue,
            reason:
                '"$reason" is emitted natively but unknown to '
                'PrintlyErrorCode and not in the documented allowlist',
          );
        }
      }
    });

    test('every Kotlin reason also exists in Swift', () {
      // Swift is the superset: it additionally defines iOS-only reasons
      // (peripheral_unknown, classic_requires_mfi) and the native-internal
      // strings Android currently keeps inline.
      expect(swift.strings['Reasons'], containsAll(kotlin.strings['Reasons']!));
    });
  });
}

String _capitalize(String s) => s[0].toUpperCase() + s.substring(1);

/// Minimal section-aware parser for the two native wire files.
///
/// Kotlin: `object Section { const val NAME = … }` with SCREAMING_SNAKE names
/// (normalized to lowerCamel). Swift: `enum Section { static let name = … }`.
/// Top-level integer constants land in [ints]; quoted constants land in
/// [strings] under their section name.
class _ParsedWire {
  _ParsedWire(this.strings, this.ints);

  factory _ParsedWire.parse(String source) {
    final Map<String, Set<String>> strings = <String, Set<String>>{};
    final Map<String, int> ints = <String, int>{};

    final RegExp sectionRe = RegExp(r'^\s*(?:object|enum)\s+(\w+)\s*\{');
    final RegExp stringRe = RegExp(
      r'(?:const val|static let)\s+(\w+)\s*=\s*"([^"]*)"',
    );
    final RegExp intRe = RegExp(
      r'(?:const val|static let)\s+(\w+)\s*=\s*(\d+)\s*$',
    );

    String section = '';
    for (final String line in source.split('\n')) {
      final RegExpMatch? sec = sectionRe.firstMatch(line);
      if (sec != null) {
        // `enum WireCodes` itself is the top level, not a subsection.
        section = sec.group(1) == 'WireCodes' ? '' : sec.group(1)!;
        continue;
      }
      final RegExpMatch? str = stringRe.firstMatch(line);
      if (str != null) {
        strings.putIfAbsent(section, () => <String>{}).add(str.group(2)!);
        continue;
      }
      final RegExpMatch? number = intRe.firstMatch(line);
      if (number != null) {
        ints[_lowerCamel(number.group(1)!)] = int.parse(number.group(2)!);
      }
    }
    return _ParsedWire(strings, ints);
  }

  /// Section name → set of string constant VALUES in that section.
  final Map<String, Set<String>> strings;

  /// lowerCamel constant name → integer value (top-level codes).
  final Map<String, int> ints;

  static String _lowerCamel(String name) {
    if (!name.contains('_')) return name;
    final List<String> parts = name.toLowerCase().split('_');
    return parts.first + parts.skip(1).map((String p) => _capitalize(p)).join();
  }
}

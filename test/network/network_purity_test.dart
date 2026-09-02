import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The network transport must stay renderer-free.
///
/// Everything under `lib/src/network/` is pure `dart:io` + typed-array work:
/// no engine, no binding, no widget tree. That is what lets it move to any
/// Dart runtime (desktop, server, isolate) and be tested against a plain
/// loopback socket instead of a device.
///
/// This test exists because that boundary is invisible at a call site — an
/// `import 'dart:ui'` or `package:flutter/…` added for one convenience would
/// erase it silently.
void main() {
  const List<String> pureFiles = <String>[
    'lib/src/network/network_address.dart',
    'lib/src/network/tcp_printer_transport.dart',
  ];

  // Dart accepts either quote style and no lint here forces one
  // (`prefer_single_quotes` is not enabled), so this needle must be
  // quote-agnostic: a `contains("'dart:ui'")` check would wave
  // `import "dart:ui";` straight through with every gate green. `dart:ui_web`
  // is the web-only twin and is just as much a renderer dependency.
  final RegExp renderer = RegExp(
    r'''(['"])dart:ui(_web)?\1|package:flutter/''',
  );

  for (final String path in pureFiles) {
    test('$path imports no renderer', () {
      final File file = File(path);
      expect(file.existsSync(), isTrue, reason: '$path is missing');
      final List<String> offenders = file
          .readAsLinesSync()
          .where((String line) {
            final String trimmed = line.trimLeft();
            if (!trimmed.startsWith('import ') &&
                !trimmed.startsWith('export ')) {
              return false;
            }
            return renderer.hasMatch(trimmed);
          })
          .toList(growable: false);
      expect(
        offenders,
        isEmpty,
        reason:
            'the network transport must not depend on dart:ui or Flutter — '
            'keep lib/src/network/ pure Dart',
      );
    });
  }
}

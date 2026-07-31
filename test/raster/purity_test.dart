import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The raster core must stay renderer-free.
///
/// `PrintlyBitmap` and everything under it is pure integer work on typed
/// arrays: no engine, no binding, no widget tree. That is what makes it
/// testable in a plain `test()`, cheap to move into an isolate, and reusable
/// with pixels from any source. `printly_raster.dart` is the single file
/// allowed to reach for the renderer.
///
/// This test exists because that boundary is invisible at a call site — an
/// `import 'dart:ui'` added for one convenience would erase it silently.
void main() {
  const List<String> pureFiles = <String>[
    'lib/src/raster/printly_bitmap.dart',
    'lib/src/raster/printly_dithering.dart',
    'lib/src/raster/raster_dither.dart',
    'lib/src/raster/raster_encoder.dart',
  ];

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
            return trimmed.contains("'dart:ui'") ||
                trimmed.contains("package:flutter/");
          })
          .toList(growable: false);
      expect(
        offenders,
        isEmpty,
        reason:
            'the raster core must not depend on dart:ui or Flutter — '
            'put renderer work in lib/src/raster/printly_raster.dart',
      );
    });
  }
}

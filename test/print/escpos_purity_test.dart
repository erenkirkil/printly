import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `EscPosEncoder` and its supporting print enums/utilities must stay pure Dart
/// — free of `dart:ui`, Flutter, and `esc_pos_utils_plus`.
void main() {
  const List<String> purePrintFiles = <String>[
    'lib/src/print/escpos_encoder.dart',
    'lib/src/print/printly_barcode_type.dart',
    'lib/src/print/printly_charset.dart',
    'lib/src/print/printly_cut_mode.dart',
    'lib/src/print/printly_hri_position.dart',
    'lib/src/print/printly_paper_width.dart',
    'lib/src/print/printly_qr_error_level.dart',
    'lib/src/print/printly_text_align.dart',
    'lib/src/print/printly_text_size.dart',
    'lib/src/print/printly_text_style.dart',
    'lib/src/print/printly_unmappable.dart',
    'lib/src/print/qr_sizing.dart',
    'lib/src/print/turkish_code_page.dart',
  ];

  for (final String path in purePrintFiles) {
    test('$path imports no Flutter, dart:ui, or esc_pos_utils_plus', () {
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
                trimmed.contains('package:flutter/') ||
                trimmed.contains('package:esc_pos_utils_plus/');
          })
          .toList(growable: false);
      expect(
        offenders,
        isEmpty,
        reason:
            '$path must stay pure Dart without Flutter, dart:ui, or '
            'esc_pos_utils_plus imports',
      );
    });
  }

  test(
    'escpos_encoder.dart only imports dart:typed_data and local printly enums',
    () {
      final List<String> imports = File('lib/src/print/escpos_encoder.dart')
          .readAsLinesSync()
          .map((String line) => line.trim())
          .where(
            (String line) =>
                line.startsWith('import ') || line.startsWith('export '),
          )
          .toList(growable: false);

      for (final String line in imports) {
        final bool allowed =
            line == "import 'dart:typed_data';" ||
            RegExp(r"^import 'printly_[a-z0-9_]+\.dart';$").hasMatch(line);
        expect(
          allowed,
          isTrue,
          reason: 'Unexpected import in escpos_encoder.dart: $line',
        );
      }
    },
  );
}

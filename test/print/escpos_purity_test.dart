import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `EscPosEncoder` and its supporting print enums/utilities must stay pure Dart
/// — free of `dart:ui`, Flutter, and `esc_pos_utils_plus`.
void main() {
  const List<String> purePrintFiles = <String>[
    'lib/src/print/escpos_encoder.dart',
    'lib/src/print/print_config.dart',
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

  final Set<String> allowedBasenames = purePrintFiles
      .map((String p) => p.split('/').last)
      .toSet();

  // Quote-agnostic check matching single or double quotes, dart:ui_web,
  // Flutter, and esc_pos_utils_plus.
  final RegExp forbidden = RegExp(
    r'''(['"])dart:ui(_web)?\1|package:flutter/|package:esc_pos_utils_plus/''',
  );

  // Every import in a pure print file must come from a safe dart:* core library,
  // another pure print sibling, or the pure raster encoder.
  final RegExp allowedDirective = RegExp(
    r'''^import\s+(['"])(dart:(convert|math|typed_data)|\.\./raster/raster_encoder\.dart|[a-z0-9_]+\.dart)\1''',
  );

  for (final String path in purePrintFiles) {
    test('$path imports only pure Dart dependencies', () {
      final File file = File(path);
      expect(file.existsSync(), isTrue, reason: '$path is missing');
      final List<String> directives = file
          .readAsLinesSync()
          .map((String line) => line.trim())
          .where(
            (String line) =>
                line.startsWith('import ') || line.startsWith('export '),
          )
          .toList(growable: false);

      for (final String line in directives) {
        expect(
          forbidden.hasMatch(line),
          isFalse,
          reason:
              '$path must not depend on dart:ui, Flutter, or '
              'esc_pos_utils_plus: $line',
        );
        final RegExpMatch? match = allowedDirective.firstMatch(line);
        expect(
          match,
          isNotNull,
          reason: 'Unexpected directive in $path: $line',
        );
        final String target = match!.group(2)!;
        if (!target.startsWith('dart:') && !target.startsWith('../raster/')) {
          expect(
            allowedBasenames.contains(target),
            isTrue,
            reason:
                '$path imports sibling "$target" which is not in purePrintFiles',
          );
        }
      }
    });
  }

  test(
    'escpos_encoder.dart only imports dart:typed_data and local printly enums',
    () {
      final RegExp allowedEncoderImport = RegExp(
        r'''^import\s+(['"])(dart:typed_data|printly_[a-z0-9_]+\.dart)\1;$''',
      );
      final List<String> imports = File('lib/src/print/escpos_encoder.dart')
          .readAsLinesSync()
          .map((String line) => line.trim())
          .where(
            (String line) =>
                line.startsWith('import ') || line.startsWith('export '),
          )
          .toList(growable: false);

      for (final String line in imports) {
        expect(
          allowedEncoderImport.hasMatch(line),
          isTrue,
          reason: 'Unexpected import in escpos_encoder.dart: $line',
        );
      }
    },
  );
}

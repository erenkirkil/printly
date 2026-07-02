import 'package:flutter_test/flutter_test.dart';
import 'package:printly/src/print/printly_qr_error_level.dart';
import 'package:printly/src/print/qr_sizing.dart';

void main() {
  group('QrSizing.moduleCountForVersion', () {
    test('uses the 17 + 4×version formula', () {
      expect(QrSizing.moduleCountForVersion(1), 21);
      expect(QrSizing.moduleCountForVersion(5), 37);
      expect(QrSizing.moduleCountForVersion(10), 57);
    });
  });

  group('QrSizing.estimateVersion', () {
    test('picks the smallest version that fits the payload', () {
      expect(QrSizing.estimateVersion(17, PrintlyQrErrorLevel.low), 1);
      expect(QrSizing.estimateVersion(18, PrintlyQrErrorLevel.low), 2);
      expect(QrSizing.estimateVersion(100, PrintlyQrErrorLevel.low), 5);
    });

    test('higher error correction needs a larger version', () {
      // 100 bytes: L fits at v5 (cap 106); H needs v10 (v9 cap 98 < 100 ≤ 119).
      expect(QrSizing.estimateVersion(100, PrintlyQrErrorLevel.high), 10);
    });

    test('caps at version 15 for oversized payloads', () {
      expect(QrSizing.estimateVersion(5000, PrintlyQrErrorLevel.low), 15);
    });
  });

  group('QrSizing.moduleSize', () {
    test('matches the roadmap worked example (100 chars on 58 mm → 8)', () {
      final int size = QrSizing.moduleSize(
        data: 'A' * 100,
        errorLevel: PrintlyQrErrorLevel.low,
        paperDots: 384,
      );
      expect(size, 8);
    });

    test('clamps to the 8-dot ceiling on wide paper', () {
      final int size = QrSizing.moduleSize(
        data: 'A' * 100,
        errorLevel: PrintlyQrErrorLevel.low,
        paperDots: 576,
      );
      expect(size, 8);
    });

    test('honours a caller maxModuleSize override', () {
      final int size = QrSizing.moduleSize(
        data: 'A' * 100,
        errorLevel: PrintlyQrErrorLevel.low,
        paperDots: 384,
        maxModuleSize: 6,
      );
      expect(size, 6);
    });

    test('shrinks the module size for a dense symbol', () {
      // ~600 bytes → version 15 (77 modules) → 384 / (77+8) = 4.
      final int size = QrSizing.moduleSize(
        data: 'A' * 600,
        errorLevel: PrintlyQrErrorLevel.low,
        paperDots: 384,
      );
      expect(size, 4);
    });

    test('never returns below the 1-dot floor', () {
      final int size = QrSizing.moduleSize(
        data: 'A' * 600,
        errorLevel: PrintlyQrErrorLevel.high,
        paperDots: 384,
        maxModuleSize: 0,
      );
      expect(size, QrSizing.minModuleSize);
    });
  });
}

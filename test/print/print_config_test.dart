import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';

void main() {
  group('PrintConfig defaults', () {
    test('has receipt-friendly defaults', () {
      const PrintConfig config = PrintConfig();
      expect(config.paperWidth, PrintlyPaperWidth.mm58);
      expect(config.charset, PrintlyCharset.latin);
      expect(config.feedLines, 0);
      expect(config.cutAfterPrint, isFalse);
      expect(config.cutMode, PrintlyCutMode.full);
    });

    test('rejects negative feedLines', () {
      expect(() => PrintConfig(feedLines: -1), throwsAssertionError);
    });
  });

  group('PrintConfig.copyWith', () {
    const PrintConfig base = PrintConfig(
      paperWidth: PrintlyPaperWidth.mm80,
      charset: PrintlyCharset.turkish,
      feedLines: 3,
      cutAfterPrint: true,
      cutMode: PrintlyCutMode.partial,
    );

    test('round-trip with no arguments preserves every field', () {
      final PrintConfig copy = base.copyWith();
      expect(copy.paperWidth, base.paperWidth);
      expect(copy.charset, base.charset);
      expect(copy.feedLines, base.feedLines);
      expect(copy.cutAfterPrint, base.cutAfterPrint);
      expect(copy.cutMode, base.cutMode);
    });

    test('replaces exactly one field, preserving the rest', () {
      final PrintConfig copy = base.copyWith(
        charset: PrintlyCharset.windows1254,
      );
      expect(copy.charset, PrintlyCharset.windows1254);
      expect(copy.paperWidth, base.paperWidth);
      expect(copy.feedLines, base.feedLines);
      expect(copy.cutAfterPrint, base.cutAfterPrint);
      expect(copy.cutMode, base.cutMode);
    });

    test('each field is individually replaceable', () {
      expect(
        base.copyWith(paperWidth: PrintlyPaperWidth.mm58).paperWidth,
        PrintlyPaperWidth.mm58,
      );
      expect(base.copyWith(feedLines: 0).feedLines, 0);
      expect(base.copyWith(cutAfterPrint: false).cutAfterPrint, isFalse);
      expect(
        base.copyWith(cutMode: PrintlyCutMode.full).cutMode,
        PrintlyCutMode.full,
      );
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:printly/src/print/printly_charset.dart';
import 'package:printly/src/print/printly_paper_width.dart';
import 'package:printly/src/print/printly_text_size.dart';
import 'package:printly/src/print/printly_text_style.dart';

void main() {
  group('domain getters', () {
    test('PaperWidth dot widths and char counts', () {
      expect(PrintlyPaperWidth.mm58.dots, 384);
      expect(PrintlyPaperWidth.mm80.dots, 576);
      expect(PrintlyPaperWidth.mm58.maxCharsPerLine, 32);
      expect(PrintlyPaperWidth.mm80.maxCharsPerLine, 48);
    });

    test('Charset ESC t selector codes', () {
      expect(PrintlyCharset.latin.escTCode, 0);
      expect(PrintlyCharset.turkish.escTCode, 13);
      expect(PrintlyCharset.windows1254.escTCode, 48);
      expect(PrintlyCharset.iso8859_9.escTCode, 48);
      expect(PrintlyCharset.utf8.escTCode, isNull);
    });

    test('TextStyle bold/underline flags', () {
      expect(PrintlyTextStyle.normal.isBold, isFalse);
      expect(PrintlyTextStyle.normal.isUnderline, isFalse);
      expect(PrintlyTextStyle.bold.isBold, isTrue);
      expect(PrintlyTextStyle.bold.isUnderline, isFalse);
      expect(PrintlyTextStyle.underline.isBold, isFalse);
      expect(PrintlyTextStyle.underline.isUnderline, isTrue);
      expect(PrintlyTextStyle.boldUnderline.isBold, isTrue);
      expect(PrintlyTextStyle.boldUnderline.isUnderline, isTrue);
    });

    test('TextSize magnification factors', () {
      expect(PrintlyTextSize.normal.widthMultiplier, 1);
      expect(PrintlyTextSize.normal.heightMultiplier, 1);
      expect(PrintlyTextSize.doubleWidth.widthMultiplier, 2);
      expect(PrintlyTextSize.doubleWidth.heightMultiplier, 1);
      expect(PrintlyTextSize.doubleHeight.widthMultiplier, 1);
      expect(PrintlyTextSize.doubleHeight.heightMultiplier, 2);
      expect(PrintlyTextSize.doubleWidthHeight.widthMultiplier, 2);
      expect(PrintlyTextSize.doubleWidthHeight.heightMultiplier, 2);
    });
  });
}

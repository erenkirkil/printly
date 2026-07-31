import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';

/// Text rendering is asserted through invariants, never byte-for-byte.
///
/// `flutter test` substitutes a built-in test font in which every glyph is an
/// identical box, so absolute metrics here bear no relation to the Roboto or SF
/// text a real device lays out. Pinning exact bytes would pin the test font.
///
/// What survives that substitution — output width, monotonic growth, ink
/// present, alignment side, Turkish differing from ASCII — is asserted instead.
/// Visual correctness is a hardware question and is verified in the sessions
/// recorded in `docs/hardware-testing.md`, not in CI.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Column index of the leftmost burned dot, or -1 if the row is blank.
  int firstInkColumn(PrintlyBitmap bitmap, int row) {
    for (int x = 0; x < bitmap.width; x++) {
      final int byte = bitmap.bits[row * bitmap.widthBytes + (x >> 3)];
      if (byte & (0x80 >> (x & 7)) != 0) return x;
    }
    return -1;
  }

  bool hasInk(PrintlyBitmap bitmap) => bitmap.bits.any((int b) => b != 0);

  test('output is exactly the requested width', () async {
    final PrintlyBitmap bitmap = await PrintlyRaster.text(
      'Merhaba',
      width: 384,
    );
    expect(bitmap.width, 384);
    expect(bitmap.widthBytes, 48);
  });

  test('renders actual ink', () async {
    // The cheapest guard against the whole class of "renders an empty canvas"
    // regressions — a wrong colour, a missing drawParagraph, a zero-size
    // picture would all show up here.
    final PrintlyBitmap bitmap = await PrintlyRaster.text(
      'Merhaba',
      width: 384,
    );
    expect(bitmap.height, greaterThan(0));
    expect(hasInk(bitmap), isTrue);
  });

  test('the background stays white', () async {
    // If the transparent canvas were read without compositing onto white, every
    // bit would be set and the receipt would come out solid black.
    final PrintlyBitmap bitmap = await PrintlyRaster.text('.', width: 384);
    final int inked = bitmap.bits.where((int b) => b != 0).length;
    expect(inked, lessThan(bitmap.byteLength ~/ 2));
  });

  test('Turkish glyphs differ from their ASCII lookalikes', () async {
    // The reason this pipeline exists: a printer stuck on CP437 cannot render
    // these, and the raster path must not be quietly folding them down either.
    final PrintlyBitmap turkish = await PrintlyRaster.text(
      'ŞşĞğİıÇç',
      width: 384,
    );
    final PrintlyBitmap ascii = await PrintlyRaster.text(
      'SsGgIiCc',
      width: 384,
    );
    expect(hasInk(turkish), isTrue);
    expect(turkish.bits, isNot(ascii.bits));
  });

  test('height grows with the type size', () async {
    final PrintlyBitmap small = await PrintlyRaster.text(
      'Merhaba',
      width: 384,
      fontSize: 16,
    );
    final PrintlyBitmap large = await PrintlyRaster.text(
      'Merhaba',
      width: 384,
      fontSize: 32,
    );
    expect(large.height, greaterThan(small.height));
  });

  test('long content wraps onto more lines', () async {
    final PrintlyBitmap oneLine = await PrintlyRaster.text(
      'Merhaba',
      width: 384,
      fontSize: 24,
    );
    final PrintlyBitmap wrapped = await PrintlyRaster.text(
      List<String>.filled(40, 'Merhaba').join(' '),
      width: 384,
      fontSize: 24,
    );
    expect(wrapped.height, greaterThan(oneLine.height * 2));
  });

  test('alignment moves the ink, not the block', () async {
    final PrintlyBitmap left = await PrintlyRaster.text(
      'Ab',
      width: 384,
      align: PrintlyTextAlign.left,
    );
    final PrintlyBitmap right = await PrintlyRaster.text(
      'Ab',
      width: 384,
      align: PrintlyTextAlign.right,
    );
    expect(left.width, right.width);

    final int leftInk = firstInkColumn(left, left.height ~/ 2);
    final int rightInk = firstInkColumn(right, right.height ~/ 2);
    expect(leftInk, greaterThanOrEqualTo(0), reason: 'left row has ink');
    expect(
      rightInk,
      greaterThan(leftInk),
      reason: 'right-aligned starts later',
    );
  });

  test('empty content yields an empty bitmap', () async {
    final PrintlyBitmap bitmap = await PrintlyRaster.text('', width: 384);
    expect(bitmap.isEmpty, isTrue);
    expect(bitmap.height, 0);
    expect(bitmap.byteLength, 0);
  });

  test('rejects a non-positive type size', () async {
    await expectLater(
      PrintlyRaster.text('x', width: 384, fontSize: 0),
      throwsArgumentError,
    );
  });
}

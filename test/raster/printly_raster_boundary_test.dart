import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';

/// Widget capture is the one raster path that needs a live widget tree.
///
/// Every capture here goes through `tester.runAsync`. `RenderRepaintBoundary
/// .toImage` completes on a real engine callback, and `testWidgets` runs inside
/// a fake-async zone that never pumps it — without `runAsync` the future simply
/// never resolves and the test times out with no useful message.
void main() {
  Widget host(GlobalKey key, {required Widget child, bool offstage = false}) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Offstage(
            offstage: offstage,
            child: RepaintBoundary(key: key, child: child),
          ),
        ),
      ),
    );
  }

  testWidgets('captures a painted boundary at the requested width', (
    WidgetTester tester,
  ) async {
    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(
      host(
        key,
        child: const SizedBox(
          width: 64,
          height: 32,
          child: ColoredBox(color: Colors.black),
        ),
      ),
    );

    final PrintlyBitmap? bitmap = await tester.runAsync(
      () => PrintlyRaster.widgetKey(key, width: 64),
    );

    expect(bitmap, isNotNull);
    expect(bitmap!.width, 64);
    expect(bitmap.height, 32);
    expect(
      bitmap.bits.every((int b) => b == 0xFF),
      isTrue,
      reason: 'a solid black box must burn every dot',
    );
  });

  testWidgets('scales the capture to the target width', (
    WidgetTester tester,
  ) async {
    // The boundary is 64 logical pixels wide but the caller wants 128 dots, so
    // the pixel ratio is derived rather than asked for.
    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(
      host(
        key,
        child: const SizedBox(
          width: 64,
          height: 16,
          child: ColoredBox(color: Colors.black),
        ),
      ),
    );

    final PrintlyBitmap? bitmap = await tester.runAsync(
      () => PrintlyRaster.widgetKey(key, width: 128),
    );

    expect(bitmap!.width, 128);
    expect(bitmap.height, 32, reason: 'height scales with the same ratio');
  });

  testWidgets('a white child leaves the paper blank', (
    WidgetTester tester,
  ) async {
    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(
      host(
        key,
        child: const SizedBox(
          width: 64,
          height: 16,
          child: ColoredBox(color: Colors.white),
        ),
      ),
    );

    final PrintlyBitmap? bitmap = await tester.runAsync(
      () => PrintlyRaster.widgetKey(key, width: 64),
    );

    expect(bitmap!.bits.every((int b) => b == 0x00), isTrue);
  });

  testWidgets('an unmounted key is rejected with a clear error', (
    WidgetTester tester,
  ) async {
    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(() => PrintlyRaster.widgetKey(key, width: 64), throwsArgumentError);
  });

  testWidgets('a key on something other than a RepaintBoundary is rejected', (
    WidgetTester tester,
  ) async {
    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(home: SizedBox(key: key, width: 64, height: 16)),
    );
    expect(() => PrintlyRaster.widgetKey(key, width: 64), throwsArgumentError);
  });

  testWidgets('an offstage boundary is rejected instead of crashing', (
    WidgetTester tester,
  ) async {
    // Offstage lays out but never paints, so there is no layer to read. This is
    // the first thing people reach for when they want to render "off screen",
    // and it needs to fail with an explanation rather than an engine assert.
    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(
      host(
        key,
        offstage: true,
        child: const SizedBox(
          width: 64,
          height: 16,
          child: ColoredBox(color: Colors.black),
        ),
      ),
    );
    expect(() => PrintlyRaster.widgetKey(key, width: 64), throwsStateError);
  });
}

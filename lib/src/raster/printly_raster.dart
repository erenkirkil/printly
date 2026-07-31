import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../print/printly_text_align.dart';
import 'printly_bitmap.dart';
import 'printly_dithering.dart';

/// Renders text, images and widgets into printable [PrintlyBitmap]s.
///
/// This is the only file in the raster layer that touches the renderer;
/// everything downstream of a [PrintlyBitmap] is pure synchronous byte work.
/// The split is what keeps `PrintJob` cascadable — render once, up front, then
/// stamp the result into as many jobs as you like:
///
/// ```dart
/// final header = await PrintlyRaster.text('MAĞAZA', width: 384, bold: true);
/// job..bitmap(header)..text('...')..cut();
/// ```
///
/// Rendering is asynchronous because there is no synchronous way back from the
/// GPU: `Picture.toImageSync` hands over an image handle, but reading its
/// pixels is still a `Future`.
///
/// **Why any of this exists:** printers in the PTP-II class ignore `ESC t`
/// outright and stay on CP437 forever, which makes Turkish text impossible
/// through the code-page path. Drawing the glyphs and sending dots sidesteps
/// the printer's character set entirely.
abstract final class PrintlyRaster {
  /// Provisional default type size, in dots.
  ///
  /// At 203 dpi (8 dots/mm) this is a 3 mm body — comfortably readable on
  /// thermal paper. Marked provisional because the right value is a question
  /// for paper, not for code: a printed size ladder is queued in
  /// `docs/hardware-testing.md`, and this constant will be set from it.
  static const double defaultFontSize = 24;

  /// Cutoff used by [text], deliberately lighter than
  /// [PrintlyBitmap.defaultThreshold].
  ///
  /// A font rasteriser antialiases: a glyph stem at receipt sizes is a dark
  /// core one dot wide with grey shoulders either side. At the neutral 128
  /// cutoff only the core burns, and a thermal head renders isolated single
  /// dots weakly — so ordinary weights come out visibly washed out while bold
  /// text, whose core is thick enough on its own, looks fine. Measured on a
  /// Cashino PTP-II; see `docs/hardware-testing.md`.
  ///
  /// Raising the cutoff burns the shoulders too, which is what puts the stroke
  /// back. Push it higher for a fainter printer, lower if letters start to fill
  /// in.
  static const int defaultTextThreshold = 176;

  /// Decodes [encoded] (PNG, JPEG, GIF, WebP, BMP — whatever the engine
  /// supports) and reduces it to dots.
  ///
  /// [width] is a **ceiling**, not a fixed size. Images wider than it are
  /// scaled down by the decoder, preserving aspect ratio; narrower images keep
  /// their own size rather than being blown up into a blurry mess. A narrow
  /// bitmap is not padded to the paper width either — pass it to
  /// `PrintJob.bitmap(align: ...)` and the printer centres it, which is
  /// verified behaviour on real hardware.
  ///
  /// Beware of coverage, not just size: a large area of solid black draws more
  /// current than a cheap 5 V head can sustain, and the printer can brown out
  /// mid-receipt with no error to catch. Line art beats photographs, and
  /// [PrintlyDithering.floydSteinberg] helps by scattering the burned dots
  /// instead of running them together.
  static Future<PrintlyBitmap> image(
    Uint8List encoded, {
    required int width,
    PrintlyDithering dithering = PrintlyDithering.floydSteinberg,
    int threshold = PrintlyBitmap.defaultThreshold,
  }) async {
    final int ceiling = PrintlyBitmap.alignWidth(width);

    // The ceiling is enforced here rather than left to the codec.
    // `instantiateImageCodec` documents `allowUpscaling: false` as capping the
    // target at the image's intrinsic size, but in practice it happily scaled
    // an 8-dot source up to 384. Reading the intrinsic size from the descriptor
    // first costs one cheap header parse and makes the behaviour ours.
    // Everything stays alive until the pixels have been read. The codec decodes
    // lazily, so releasing the buffer or the descriptor as soon as the codec
    // exists — which reads as the tidy thing to do — makes `getNextFrame` fail
    // with "Codec failed to produce an image".
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
      encoded,
    );
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width < PrintlyBitmap.minWidth) {
        throw ArgumentError.value(
          descriptor.width,
          'encoded',
          'image is narrower than ${PrintlyBitmap.minWidth} dots',
        );
      }
      final int target = PrintlyBitmap.alignWidth(
        descriptor.width < ceiling ? descriptor.width : ceiling,
      );
      codec = await descriptor.instantiateCodec(targetWidth: target);

      final ui.FrameInfo frame = await codec.getNextFrame();
      final ui.Image decoded = frame.image;
      try {
        return await _rasterise(
          decoded,
          width: target,
          dithering: dithering,
          threshold: threshold,
        );
      } finally {
        decoded.dispose();
      }
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  /// Lays out [content] to exactly [width] dots and draws it.
  ///
  /// This is the Turkish-text path. The glyphs are shaped by the platform's own
  /// text engine — the same one behind every `Text` widget — so `ğ`, `İ` and
  /// the rest come out right regardless of what code pages the printer knows.
  ///
  /// Wrapping is automatic. The returned bitmap is as tall as the laid-out
  /// paragraph and exactly [width] dots wide, so [align] positions the text
  /// within the line rather than moving the block.
  ///
  /// An empty [content] yields an empty bitmap, which `PrintJob.bitmap` skips
  /// entirely rather than emitting a zero-height raster command.
  static Future<PrintlyBitmap> text(
    String content, {
    required int width,
    double fontSize = defaultFontSize,
    PrintlyTextAlign align = PrintlyTextAlign.left,
    bool bold = false,
    String? fontFamily,
    PrintlyDithering dithering = PrintlyDithering.threshold,
    int threshold = defaultTextThreshold,
  }) async {
    final int target = PrintlyBitmap.alignWidth(width);
    if (content.isEmpty) {
      return PrintlyBitmap.blank(width: target, height: 0);
    }
    if (fontSize <= 0) {
      throw ArgumentError.value(fontSize, 'fontSize', 'must be positive');
    }

    final ui.FontWeight weight = bold
        ? ui.FontWeight.bold
        : ui.FontWeight.normal;
    final ui.ParagraphBuilder builder =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(
              textAlign: _toUiTextAlign(align),
              textDirection: ui.TextDirection.ltr,
              fontFamily: fontFamily,
              fontSize: fontSize,
              fontWeight: weight,
            ),
          )
          ..pushStyle(
            ui.TextStyle(
              color: const ui.Color(0xFF000000),
              fontFamily: fontFamily,
              fontSize: fontSize,
              fontWeight: weight,
            ),
          )
          ..addText(content);

    final ui.Paragraph paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: target.toDouble()));
    try {
      final int height = paragraph.height.ceil();
      if (height <= 0) return PrintlyBitmap.blank(width: target, height: 0);

      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final ui.Canvas canvas = ui.Canvas(recorder);
      // Paint the paper before the ink. Without this the canvas is fully
      // transparent, and while the luminance pass composites transparency onto
      // white anyway, relying on that alone would leave a single missed
      // composite between here and a receipt printed solid black.
      canvas
        ..drawRect(
          ui.Rect.fromLTWH(0, 0, target.toDouble(), height.toDouble()),
          ui.Paint()..color = const ui.Color(0xFFFFFFFF),
        )
        ..drawParagraph(paragraph, ui.Offset.zero);

      final ui.Picture picture = recorder.endRecording();
      try {
        final ui.Image image = await picture.toImage(target, height);
        try {
          return await _rasterise(
            image,
            width: target,
            dithering: dithering,
            threshold: threshold,
          );
        } finally {
          image.dispose();
        }
      } finally {
        picture.dispose();
      }
    } finally {
      paragraph.dispose();
    }
  }

  /// Captures an already-painted [RenderRepaintBoundary].
  ///
  /// The boundary must be **mounted and painted**. Capture reads the layer the
  /// last paint produced, so anything that skips painting yields nothing to
  /// read: `Offstage(offstage: true)` lays out but never paints,
  /// `Opacity(opacity: 0)` skips its child, and a subtree that has not been
  /// laid out has no layer at all. Keep the boundary on screen — a visible
  /// receipt preview is the natural way to satisfy this, and it doubles as a
  /// preview for the user.
  ///
  /// The scale factor is derived, not asked for: the boundary is captured at
  /// exactly [width] dots regardless of its logical size. Size the boundary in
  /// logical pixels to match the paper (384 for 58 mm) and wrap it in a
  /// `FittedBox` for display — transforms above the boundary do not affect what
  /// is captured.
  static Future<PrintlyBitmap> repaintBoundary(
    RenderRepaintBoundary boundary, {
    required int width,
    PrintlyDithering dithering = PrintlyDithering.threshold,
    int threshold = defaultTextThreshold,
  }) async {
    final int target = PrintlyBitmap.alignWidth(width);
    final Size size = boundary.size;
    if (size.width <= 0 || size.height <= 0) {
      throw StateError(
        'the RepaintBoundary has no size (${size.width} x ${size.height}); '
        'it must be laid out before it can be captured',
      );
    }
    // Debug-only diagnosis: both accessors are stripped in release builds. The
    // point is to turn an engine-level crash into a sentence that says what to
    // do, while the developer is still the one looking at it.
    bool unpainted = false;
    assert(() {
      unpainted = boundary.debugNeedsPaint || boundary.debugLayer == null;
      return true;
    }());
    if (unpainted) {
      throw StateError(
        'the RepaintBoundary has not been painted yet; keep it mounted and '
        'visible — Offstage and Opacity(0) subtrees are never painted',
      );
    }

    final ui.Image image = await boundary.toImage(
      pixelRatio: target / size.width,
    );
    try {
      return await _rasterise(
        image,
        width: target,
        dithering: dithering,
        threshold: threshold,
      );
    } finally {
      image.dispose();
    }
  }

  /// Resolves [key] to its [RenderRepaintBoundary] and captures it.
  ///
  /// Convenience over [repaintBoundary] for the usual arrangement: a
  /// `RepaintBoundary(key: myKey, child: ...)` somewhere in the tree.
  ///
  /// Takes a key rather than a widget because there is no supported way on
  /// Flutter 3.35 to render a detached widget: building one needs a
  /// `RenderView`, a `RenderView` needs a `FlutterView`, and one cannot be
  /// fabricated. An API that accepted a `Widget` would have to lie about that.
  static Future<PrintlyBitmap> widgetKey(
    GlobalKey key, {
    required int width,
    PrintlyDithering dithering = PrintlyDithering.threshold,
    int threshold = defaultTextThreshold,
  }) {
    final BuildContext? context = key.currentContext;
    if (context == null) {
      throw ArgumentError.value(
        key,
        'key',
        'is not attached to a mounted widget',
      );
    }
    final RenderObject? object = context.findRenderObject();
    if (object is! RenderRepaintBoundary) {
      throw ArgumentError.value(
        key,
        'key',
        'must be attached to a RepaintBoundary, found ${object.runtimeType}',
      );
    }
    return repaintBoundary(
      object,
      width: width,
      dithering: dithering,
      threshold: threshold,
    );
  }

  /// Reads an image's pixels and hands them to the pure core.
  static Future<PrintlyBitmap> _rasterise(
    ui.Image image, {
    required int width,
    required PrintlyDithering dithering,
    required int threshold,
  }) async {
    // rawRgba is premultiplied, which is what PrintlyBitmap expects and what
    // makes the white composite a single addition.
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    if (data == null) {
      throw StateError('the engine returned no pixels for the rendered image');
    }
    return PrintlyBitmap.fromPremultipliedRgba(
      rgba: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      sourceWidth: image.width,
      sourceHeight: image.height,
      width: width,
      dithering: dithering,
      threshold: threshold,
    );
  }

  static ui.TextAlign _toUiTextAlign(PrintlyTextAlign align) => switch (align) {
    PrintlyTextAlign.left => ui.TextAlign.left,
    PrintlyTextAlign.center => ui.TextAlign.center,
    PrintlyTextAlign.right => ui.TextAlign.right,
  };
}

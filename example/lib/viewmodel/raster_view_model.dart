import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:printly/printly.dart';

import '../model/image_fetcher.dart';
import 'action_log_view_model.dart';
import 'settings_view_model.dart';

/// Drives the raster lab: renders Turkish text to dots, previews the result on
/// screen, and prints it once it looks right.
///
/// The preview is the point. `flutter test` uses a stand-in font in which every
/// glyph is the same box, so no unit test can tell you whether 24-dot type is
/// actually readable on paper — but a preview of the real dithered output can,
/// without spending any.
class RasterViewModel extends ChangeNotifier {
  RasterViewModel({
    required ActionLogViewModel log,
    required SettingsViewModel settings,
  }) : _log = log,
       _settings = settings;

  final ActionLogViewModel _log;
  final SettingsViewModel _settings;

  static const String _sampleText =
      'PRINTLY MAĞAZA\n'
      'Çağrı Şişli - İstanbul\n'
      'Ürün: Türk Kahvesi\n'
      'ĞÜŞİÖÇ ğüşıöç\n'
      'Teşekkür ederiz!';

  String _text = _sampleText;
  double _fontSize = PrintlyRaster.defaultFontSize;
  bool _bold = false;
  PrintlyTextAlign _align = PrintlyTextAlign.left;
  int _threshold = PrintlyRaster.defaultTextThreshold;

  /// Blank lines fed after the body.
  ///
  /// Just enough to clear the tear bar. The printer feeds roughly 4 mm per
  /// line, and the bar sits about a centimetre above the head.
  int _feedLines = 3;

  /// Off by default: the printer this was developed against has no cutter, and
  /// its firmware answers `GS V` by feeding some 25 mm of blank paper and doing
  /// nothing else. Turn it on for a printer that can actually cut.
  bool _cutAfterPrint = false;

  PrintlyBitmap? _bitmap;
  ui.Image? _preview;
  bool _rendering = false;
  bool _busy = false;
  PrintlyDevice? _activeDevice;
  StreamSubscription<PrintlyDevice?>? _activeDeviceSub;

  String get text => _text;
  double get fontSize => _fontSize;
  bool get bold => _bold;
  PrintlyTextAlign get align => _align;
  int get threshold => _threshold;
  int get feedLines => _feedLines;
  bool get cutAfterPrint => _cutAfterPrint;

  /// The rendered dots, or null before the first render.
  PrintlyBitmap? get bitmap => _bitmap;

  /// The preview image — exactly the dots that would be burned.
  ui.Image? get preview => _preview;

  bool get rendering => _rendering;
  bool get canPrint => _activeDevice != null && _bitmap != null && !_busy;

  /// Coverage past which a job is worth a second look.
  ///
  /// Not a cliff — the printer does not fail at 15.1% — but ordinary receipt
  /// text sits near 8%, so anything much above this is a solid-black area, and
  /// solid-black areas are what brown the printer out. A logo pulled off the
  /// web routinely lands at 30–40%.
  static const double coverageWarningThreshold = 0.15;

  bool get coverageIsHigh => _inkCoverage > coverageWarningThreshold;

  /// How much of the paper this receipt would blacken, as a fraction.
  ///
  /// Surfaced because coverage is a hardware limit, not a cosmetic one: a broad
  /// solid-black area draws more current than a cheap 5 V head can sustain and
  /// the printer can cut out mid-receipt with nothing for the app to catch.
  /// Ordinary text sits around 8%.
  ///
  /// Computed once per bitmap rather than on demand. It is read from `build`,
  /// and a 384×384 image is 18 KB of dots — counting them on every rebuild is
  /// enough work to be felt while dragging a slider.
  double get inkCoverage => _inkCoverage;

  double _inkCoverage = 0;

  /// Set bits per byte value.
  ///
  /// The obvious `byte.toRadixString(2).replaceAll('0', '').length` allocates
  /// two strings per byte — tens of thousands of them for one image — which is
  /// exactly the kind of thing that turns a smooth slider into a stutter.
  static final Uint8List _setBitsPerByte = Uint8List.fromList(
    List<int>.generate(256, (int value) {
      int count = 0;
      for (int bit = 0; bit < 8; bit++) {
        if (value & (1 << bit) != 0) count++;
      }
      return count;
    }),
  );

  static double _coverageOf(PrintlyBitmap bitmap) {
    if (bitmap.isEmpty) return 0;
    int burned = 0;
    for (final int byte in bitmap.bits) {
      burned += _setBitsPerByte[byte];
    }
    return burned / (bitmap.bits.length * 8);
  }

  void start() {
    _activeDeviceSub = Printly.instance.activeDeviceStream.listen((
      PrintlyDevice? device,
    ) {
      _activeDevice = device;
      notifyListeners();
    });
    unawaited(render());
  }

  set text(String value) {
    if (_text == value) return;
    _text = value;
    unawaited(render());
  }

  set fontSize(double value) {
    if (_fontSize == value) return;
    _fontSize = value;
    unawaited(render());
  }

  set bold(bool value) {
    if (_bold == value) return;
    _bold = value;
    unawaited(render());
  }

  set align(PrintlyTextAlign value) {
    if (_align == value) return;
    _align = value;
    unawaited(render());
  }

  set threshold(int value) {
    if (_threshold == value) return;
    _threshold = value;
    unawaited(render());
  }

  set feedLines(int value) {
    if (_feedLines == value) return;
    _feedLines = value;
    notifyListeners();
  }

  set cutAfterPrint(bool value) {
    if (_cutAfterPrint == value) return;
    _cutAfterPrint = value;
    notifyListeners();
  }

  /// Re-renders the bitmap and its on-screen preview.
  Future<void> render() async {
    if (_rendering) return;
    _rendering = true;
    notifyListeners();
    try {
      final PrintlyBitmap rendered = await PrintlyRaster.text(
        _text,
        width: _settings.paperWidth.dots,
        fontSize: _fontSize,
        align: _align,
        bold: _bold,
        threshold: _threshold,
      );
      final ui.Image? image = rendered.isEmpty
          ? null
          : await _toImage(rendered);

      _preview?.dispose();
      _bitmap = rendered;
      _preview = image;
      _inkCoverage = _coverageOf(rendered);
    } catch (error) {
      _log.failure('raster render error → $error');
    } finally {
      _rendering = false;
      notifyListeners();
    }
  }

  /// Prints exactly the bitmap shown in the preview.
  Future<void> printPreview() async {
    final PrintlyDevice? device = _activeDevice;
    final PrintlyBitmap? rendered = _bitmap;
    if (device == null || rendered == null || _busy) return;
    _busy = true;
    notifyListeners();
    try {
      final PrintJob job = await Printly.instance.newJob(
        config: PrintConfig(
          paperWidth: _settings.paperWidth,
          feedLines: _feedLines,
          cutAfterPrint: _cutAfterPrint,
        ),
      );
      job.bitmap(rendered, align: PrintlyTextAlign.left);
      final int bytes = job.build().length;

      final Stopwatch watch = Stopwatch()..start();
      await Printly.instance.print(device, job);
      watch.stop();

      _log.success(
        'raster → ok · $bytes B in ${watch.elapsedMilliseconds} ms · '
        '${rendered.heightMm.toStringAsFixed(1)} mm · '
        '${(inkCoverage * 100).toStringAsFixed(1)}% ink',
      );
    } catch (error) {
      _log.failure('raster error → $error');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Prints the widget captured by [boundaryKey] — the receipt-preview path.
  Future<void> printWidget(GlobalKey boundaryKey) async {
    final PrintlyDevice? device = _activeDevice;
    if (device == null || _busy) return;
    _busy = true;
    notifyListeners();
    try {
      final PrintJob job = await Printly.instance.newJob(
        config: PrintConfig(
          paperWidth: _settings.paperWidth,
          feedLines: _feedLines,
          cutAfterPrint: _cutAfterPrint,
        ),
      );
      await job.widget(boundaryKey, align: PrintlyTextAlign.left);
      final int bytes = job.build().length;

      final Stopwatch watch = Stopwatch()..start();
      await Printly.instance.print(device, job);
      watch.stop();

      _log.success(
        'widget raster → ok · $bytes B in ${watch.elapsedMilliseconds} ms',
      );
    } catch (error) {
      _log.failure('widget raster error → $error');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Downloads [url], renders it to dots and shows it in the preview.
  ///
  /// The image lands in the same preview as the text so its ink coverage is
  /// visible before anything is printed — which matters more here than
  /// anywhere else, since an arbitrary photograph off the internet is exactly
  /// the kind of input that can black out a receipt and brown the printer out.
  Future<void> loadImageFromUrl(String url) async {
    if (_rendering) return;
    _rendering = true;
    notifyListeners();
    try {
      final Uint8List bytes = await ImageFetcher.fetch(url);
      final PrintlyBitmap rendered = await PrintlyRaster.image(
        bytes,
        width: _settings.paperWidth.dots,
      );
      final ui.Image image = await _toImage(rendered);

      _preview?.dispose();
      _bitmap = rendered;
      _preview = image;
      _inkCoverage = _coverageOf(rendered);
      _log.success(
        'image → ${rendered.width}×${rendered.height} · '
        '${(inkCoverage * 100).toStringAsFixed(1)}% ink · '
        '${bytes.length ~/ 1024} KB downloaded',
      );
    } catch (error) {
      _log.failure('image error → $error');
    } finally {
      _rendering = false;
      notifyListeners();
    }
  }

  void resetText() {
    text = _sampleText;
  }

  static Future<ui.Image> _toImage(PrintlyBitmap bitmap) {
    final Completer<ui.Image> completer = Completer<ui.Image>();
    final Uint8List rgba = bitmap.toRgba();
    ui.decodeImageFromPixels(
      rgba,
      bitmap.width,
      bitmap.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  @override
  void dispose() {
    unawaited(_activeDeviceSub?.cancel());
    _preview?.dispose();
    super.dispose();
  }
}

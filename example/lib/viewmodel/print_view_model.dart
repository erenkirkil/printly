import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:printly/printly.dart';

import '../model/receipt_templates.dart';
import 'action_log_view_model.dart';
import 'settings_view_model.dart';

/// Drives every print action.
///
/// Takes plain values rather than controllers — `printQr(String data)`, not
/// `printQr(TextEditingController)` — so the text controllers stay in the
/// widget's `State` and this class can be exercised without any widget
/// machinery.
class PrintViewModel extends ChangeNotifier {
  PrintViewModel({
    required ActionLogViewModel log,
    required SettingsViewModel settings,
  }) : _log = log,
       _settings = settings;

  final ActionLogViewModel _log;
  final SettingsViewModel _settings;

  PrintlyBarcodeType _barcodeType = PrintlyBarcodeType.code128;
  PrintlyQrErrorLevel _qrErrorLevel = PrintlyQrErrorLevel.medium;
  PrintlyDevice? _activeDevice;
  bool _busy = false;

  StreamSubscription<PrintlyDevice?>? _activeDeviceSub;

  PrintlyBarcodeType get barcodeType => _barcodeType;
  PrintlyQrErrorLevel get qrErrorLevel => _qrErrorLevel;

  /// Whether a job can be sent right now: a device is connected and no other
  /// write is in flight (both transports reject a concurrent write with
  /// `write_busy`).
  bool get canPrint => _activeDevice != null && !_busy;

  set barcodeType(PrintlyBarcodeType value) {
    if (_barcodeType == value) return;
    _barcodeType = value;
    notifyListeners();
  }

  set qrErrorLevel(PrintlyQrErrorLevel value) {
    if (_qrErrorLevel == value) return;
    _qrErrorLevel = value;
    notifyListeners();
  }

  void start() {
    _activeDeviceSub = Printly.instance.activeDeviceStream.listen((
      PrintlyDevice? device,
    ) {
      _activeDevice = device;
      notifyListeners();
    });
  }

  Future<void> printTurkishReceipt() =>
      _run('print', ReceiptTemplates.turkish(_settings.paperWidth));

  Future<void> printCharsetDiagnostic() => _run(
    'page sweep',
    ReceiptTemplates.charsetDiagnostic(_settings.paperWidth),
  );

  Future<void> printQr(String data) => _run(
    'qr',
    ReceiptTemplates.qr(
      _settings.paperWidth,
      data: data,
      errorLevel: _qrErrorLevel,
    ),
    detail: '${data.length} chars',
  );

  Future<void> printQrDensityDemo() =>
      _run('qr density', ReceiptTemplates.qrDensityDemo(_settings.paperWidth));

  Future<void> printBarcode(String data) => _run(
    'barcode',
    ReceiptTemplates.barcode(
      _settings.paperWidth,
      data: data,
      type: _barcodeType,
    ),
    detail: _barcodeType.name,
  );

  Future<void> printBarcodeGallery() => _run(
    'barcode gallery',
    ReceiptTemplates.barcodeGallery(_settings.paperWidth),
  );

  Future<void> printLayoutSample() =>
      _run('layout', ReceiptTemplates.layout(_settings.paperWidth));

  /// Shared print flow: create the job with the template's config, fill it,
  /// send it, and report the outcome. Every action funnels through here so the
  /// error handling and busy-state bookkeeping exist in exactly one place.
  ///
  /// The elapsed time is reported alongside the byte count. Bluetooth Classic
  /// gives a whole job a single 10-second write budget, so knowing how long a
  /// real receipt actually takes is the measurement that decides whether writes
  /// need splitting — and it comes free from prints that were happening anyway.
  Future<void> _run(
    String label,
    ReceiptTemplate template, {
    String? detail,
  }) async {
    final PrintlyDevice? device = _activeDevice;
    if (device == null || _busy) return;
    _busy = true;
    notifyListeners();
    try {
      final PrintJob job = await Printly.instance.newJob(
        config: template.config,
      );
      template.build(job);
      final int bytes = job.build().length;

      final Stopwatch watch = Stopwatch()..start();
      await Printly.instance.print(device, job);
      watch.stop();

      final String suffix =
          '$bytes B in ${watch.elapsedMilliseconds} ms'
          '${detail == null ? '' : ' · $detail'}';
      _log.success('$label → ok · $suffix');
    } catch (error) {
      _log.failure('$label error → $error');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    unawaited(_activeDeviceSub?.cancel());
    super.dispose();
  }
}

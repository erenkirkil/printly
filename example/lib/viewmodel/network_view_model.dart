import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:printly/printly.dart';

import '../model/receipt_templates.dart';
import 'action_log_view_model.dart';
import 'settings_view_model.dart';

/// Owns the whole network-printer lifecycle for the example: the address the
/// user types, the connection state, and the qualification prints used to
/// check a printer that has just been put on the network.
///
/// Takes plain values, not controllers — the `TextEditingController`s stay in
/// the widget layer so this class is testable without any widget machinery.
class NetworkViewModel extends ChangeNotifier {
  /// Creates the view model. Call [start] once mounted to begin observing
  /// connection state; the constructor stays side-effect free.
  NetworkViewModel({
    required ActionLogViewModel log,
    required SettingsViewModel settings,
  }) : _log = log,
       _settings = settings;

  /// Default raw-printing port for ESC/POS network printers.
  static const int kDefaultPort = 9100;

  final ActionLogViewModel _log;
  final SettingsViewModel _settings;

  String _host = '';
  int _port = kDefaultPort;
  ConnectionState _state = ConnectionState.disconnected;
  bool _busy = false;
  bool _started = false;
  final List<String> _recents = <String>[];

  StreamSubscription<ConnectionState>? _stateSub;

  /// Host or IP the user typed. Trimmed on read.
  String get host => _host;

  set host(String value) {
    final String trimmed = value.trim();
    if (_host == trimmed) return;
    _host = trimmed;
    _resubscribe();
    notifyListeners();
  }

  /// TCP port; defaults to [kDefaultPort].
  int get port => _port;

  set port(int value) {
    if (_port == value) return;
    _port = value;
    _resubscribe();
    notifyListeners();
  }

  /// Latest connection state for the current [device].
  ConnectionState get state => _state;

  /// Whether an action is in flight.
  bool get busy => _busy;

  /// Addresses connected to earlier in this session, most recent first.
  List<String> get recents => List<String>.unmodifiable(_recents);

  /// The device built from [host] and [port], or `null` when no host is set.
  PrintlyDevice? get device => _host.isEmpty
      ? null
      : PrintlyDevice.network(
          host: _host,
          port: _port,
          name: 'TCP $_host:$_port',
        );

  /// Whether [connect] can run now.
  bool get canConnect =>
      device != null && !_busy && _state != ConnectionState.connected;

  /// Whether a print can be sent now.
  bool get canPrint => _state == ConnectionState.connected && !_busy;

  /// Begins observing the connection state of the current device.
  ///
  /// Nothing before this call touches `Printly.instance` — see [_resubscribe].
  void start() {
    _started = true;
    _resubscribe();
  }

  /// Fills [host] and [port] from a `host:port` string in [recents].
  void useRecent(String hostPort) {
    final int sep = hostPort.lastIndexOf(':');
    if (sep <= 0) return;
    final String h = hostPort.substring(0, sep);
    final int? p = int.tryParse(hostPort.substring(sep + 1));
    if (p == null) return;
    _host = h;
    _port = p;
    _resubscribe();
    notifyListeners();
  }

  /// Re-points the state subscription at whatever [device] currently is.
  ///
  /// Silent until [start] has run. The address setters call this on every
  /// keystroke, and `Printly.instance` builds its controllers — and subscribes
  /// to the native event channels — the first time it is touched. Without the
  /// [_started] gate, merely assigning [host] would reach for a binding that
  /// does not exist in a plain unit test, and the class would break the
  /// side-effect-free promise its constructor makes.
  void _resubscribe() {
    unawaited(_stateSub?.cancel());
    _stateSub = null;
    final PrintlyDevice? d = device;
    if (!_started || d == null) {
      _state = ConnectionState.disconnected;
      return;
    }
    _state = Printly.instance.connectionStateSnapshotOf(d);
    _stateSub = Printly.instance.connectionStateOf(d).listen((
      ConnectionState s,
    ) {
      _state = s;
      notifyListeners();
    });
  }

  /// Opens a TCP connection to the current device.
  Future<void> connect() async {
    final PrintlyDevice? d = device;
    if (d == null || _busy) return;
    _busy = true;
    notifyListeners();
    try {
      await Printly.instance.connect(d);
      _log.success('network connect → ${d.address}');
      _remember(d.address);
    } catch (error) {
      _log.failure('network connect error → $error');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Closes the TCP connection to the current device.
  Future<void> disconnect() async {
    final PrintlyDevice? d = device;
    if (d == null || _busy) return;
    _busy = true;
    notifyListeners();
    try {
      await Printly.instance.disconnect(device: d);
      _log.success('network disconnect → ${d.address}');
    } catch (error) {
      _log.failure('network disconnect error → $error');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Plain ESC/POS text plus the current paper width — the first thing to try
  /// on a printer that has just come onto the network.
  Future<void> printTextTest() =>
      _run('text', ReceiptTemplates.layout(_settings.paperWidth));

  /// Turkish drawn as dots (`GS v 0`) instead of sent as code-page bytes.
  ///
  /// This is the print that qualifies a new printer for Turkish, and both
  /// field failures land here: the PTP-II ignores `ESC t` and stays on CP437,
  /// while the Custom TK180 honours `ESC t` but carries no PC857/WPC1254
  /// table. Neither can render `ğŞİ` through [PrintJob.text]; the raster path
  /// never consults the printer's font. The code-page variant of the same
  /// receipt lives on the Print tab, so the two can be compared on paper for
  /// the device connected from here.
  ///
  /// Built by hand rather than through [ReceiptTemplates] because
  /// `ReceiptTemplate.build` fills a job synchronously while
  /// [PrintJob.textRaster] renders through the engine and must be awaited — a
  /// raster receipt cannot be expressed as a template.
  Future<void> printTurkishRaster() => _send('turkish raster', () async {
    final PrintJob job = await Printly.instance.newJob(
      config: PrintConfig(
        paperWidth: _settings.paperWidth,
        feedLines: 3,
        cutAfterPrint: true,
      ),
    );
    await job.textRaster(
      'PRINTLY MAĞAZA',
      align: PrintlyTextAlign.center,
      fontSize: 32,
      bold: true,
    );
    await job.textRaster(
      'Çağrı Şişli - İstanbul',
      align: PrintlyTextAlign.center,
    );
    await job.textRaster('Ürün: Türk Kahvesi\nAdet: 2 x 45,00 = 90,00 TL');
    await job.textRaster('Teşekkür ederiz!', align: PrintlyTextAlign.center);
    return job;
  });

  /// A QR code at the current paper width.
  Future<void> printQrTest() => _run(
    'qr',
    ReceiptTemplates.qr(
      _settings.paperWidth,
      data: 'https://pub.dev/packages/printly',
      errorLevel: PrintlyQrErrorLevel.medium,
    ),
  );

  /// A short receipt that ends in a cut — verifies the cutter, and on a
  /// printer without one shows up as roughly 25 mm of blank feed instead.
  Future<void> printCutTest() => _send('cut', () async {
    final PrintJob job = await Printly.instance.newJob(
      paperWidth: _settings.paperWidth,
    );
    job
      ..text('cut test', align: PrintlyTextAlign.center)
      ..feed(2)
      ..cut();
    return job;
  });

  Future<void> _run(String label, ReceiptTemplate template) =>
      _send(label, () async {
        final PrintJob job = await Printly.instance.newJob(
          config: template.config,
        );
        template.build(job);
        return job;
      });

  /// Shared print plumbing: the connected guard, the busy flag, the log line
  /// and the `finally` that re-enables the buttons however the job ends. Only
  /// [buildJob] differs between the tests — a template fills a job
  /// synchronously, a raster job has to await the engine first — so it stays a
  /// callback instead of being duplicated four times.
  Future<void> _send(String label, Future<PrintJob> Function() buildJob) async {
    final PrintlyDevice? d = device;
    if (d == null || !canPrint) return;
    _busy = true;
    notifyListeners();
    try {
      final PrintJob job = await buildJob();
      await Printly.instance.print(d, job);
      _log.success('network print $label → ${d.address}');
    } catch (error) {
      _log.failure('network print $label error → $error');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void _remember(String address) {
    _recents
      ..remove(address)
      ..insert(0, address);
    if (_recents.length > 5) _recents.removeLast();
  }

  @override
  void dispose() {
    unawaited(_stateSub?.cancel());
    super.dispose();
  }
}

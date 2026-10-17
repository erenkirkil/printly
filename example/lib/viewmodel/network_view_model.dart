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
  NetworkViewModel({required this._log, required this._settings});

  /// Default raw-printing port for ESC/POS network printers.
  static const int kDefaultPort = 9100;

  /// Advance the ticket until the notch sits under the printing line.
  ///
  /// One of three commands from Custom's own command set (KPM180H/TK180
  /// command manual 915AH020300700, "Alignment"). They have no standard
  /// ESC/POS equivalent: `GS FF`, the usual "feed to black mark", is answered
  /// with COMMAND ERROR on this firmware.
  static const List<int> _alignToPrintHead = <int>[0x1D, 0xF6];

  /// Advance the ticket until the notch sits under the cutting line.
  static const List<int> _alignToCutter = <int>[0x1D, 0xF8];

  /// Total cut. Custom's command manual does not document `GS V` at all —
  /// which is the cut printly emits for [PrintConfig.cutAfterPrint] and
  /// [PrintJob.cut], so on this device that cut never lands and the paper is
  /// left mid-ticket. Every later job then starts misaligned, which is what
  /// made receipts straddle the perforations.
  static const List<int> _totalCut = <int>[0x1B, 0x69];

  final ActionLogViewModel _log;
  final SettingsViewModel _settings;

  String _host = '';
  int _port = kDefaultPort;
  ConnectionState _state = ConnectionState.disconnected;
  bool _busy = false;
  bool _started = false;
  bool _ticketMode = false;
  bool _alignedSinceConnect = false;
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

  /// Whether to wrap each job in Custom's ticket-alignment commands.
  ///
  /// Turn this on for fixed-length pre-notched ticket stock (a Custom TK180
  /// and its kin), where every job has to start at a ticket's top edge and be
  /// cut on its boundary. Leave it off for continuous roll paper, where there
  /// is no notch to align to and these commands would simply stall waiting for
  /// a mark that never arrives.
  bool get ticketMode => _ticketMode;

  set ticketMode(bool value) {
    if (_ticketMode == value) return;
    _ticketMode = value;
    // Switching modes says nothing about where the paper stopped, so the next
    // ticket job re-aligns rather than assuming.
    _alignedSinceConnect = false;
    notifyListeners();
  }

  /// Whether the next ticket job has to open with the align-to-print-head
  /// command (`GS F6`).
  ///
  /// True only for the first job after connecting. `ESC i` already retracts
  /// the paper to the next ticket's top edge, so sending `GS F6` again on
  /// already-aligned paper advances a whole extra ticket — measured on a
  /// TK180: identical jobs printed one ticket without it and one ticket plus
  /// a blank with it. The first job of a session still needs it, because a
  /// reload can leave the paper anywhere.
  bool get needsTicketAlignment => _ticketMode && !_alignedSinceConnect;

  /// Records that the paper is now notch-aligned, so later jobs skip `GS F6`.
  void markTicketAligned() => _alignedSinceConnect = true;

  /// Re-arms [needsTicketAlignment]. Called on every connect, where the paper
  /// may have been reloaded while the socket was closed.
  void resetTicketAlignment() => _alignedSinceConnect = false;

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
      resetTicketAlignment();
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
    final PrintJob job = await _newJob(
      PrintConfig(
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
    final PrintJob job = await _newJob(
      PrintConfig(paperWidth: _settings.paperWidth),
    );
    job
      ..text('cut test', align: PrintlyTextAlign.center)
      ..feed(2);
    // In ticket mode the cut is Custom's `ESC i`, appended by [_send] after
    // the align-to-cutter command. Calling printly's cut() here as well would
    // emit a `GS V` this device answers with COMMAND ERROR.
    if (!_ticketMode) job.cut();
    return job;
  });

  Future<void> _run(String label, ReceiptTemplate template) =>
      _send(label, () async {
        final PrintJob job = await _newJob(template.config);
        template.build(job);
        return job;
      });

  /// Creates the job every test prints through.
  ///
  /// In [ticketMode] it does two things the plain `newJob` cannot: it drops
  /// printly's automatic `GS V` cut, which this device does not implement, and
  /// it opens the job with the align-to-print-head command so the first line
  /// lands on the ticket's top edge instead of wherever the previous job
  /// stopped.
  Future<PrintJob> _newJob(PrintConfig config) async {
    final PrintJob job = await Printly.instance.newJob(
      config: _ticketMode ? ticketJobConfig(config) : config,
    );
    if (needsTicketAlignment) {
      job.raw(_alignToPrintHead);
      markTicketAligned();
    }
    return job;
  }

  /// Rewrites a roll-paper [config] for notched ticket stock.
  ///
  /// Two of the encoder's finalisers have to go. `cutAfterPrint` emits `GS V`,
  /// which this device does not implement. `feedLines` is the subtler one:
  /// [PrintJob.build] appends it *after* the job body, and the body is where
  /// [_send] put the align-to-cutter command and the `ESC i` cut — so the feed
  /// lands after the cut and pushes the paper past the notch the blade just
  /// used. The next job's `GS F6` then skips that half-fed ticket, which comes
  /// out blank. On ticket stock the alignment command is the only trailing
  /// feed a job needs; on roll paper the original config stays as it is.
  static PrintConfig ticketJobConfig(PrintConfig config) =>
      config.copyWith(cutAfterPrint: false, feedLines: 0);

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
      if (_ticketMode) {
        // Order is Custom's, not ours: align to the cutter first, then cut.
        // Cutting without the alignment leaves the blade wherever the content
        // happened to end, which is the mid-ticket fragment this replaces.
        job
          ..raw(_alignToCutter)
          ..raw(_totalCut);
      }
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

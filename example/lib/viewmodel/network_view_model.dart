import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:printly/printly.dart';

import '../model/receipt_templates.dart';
import 'action_log_view_model.dart';
import 'settings_view_model.dart';

/// Owns the whole network-printer lifecycle for the example: the address the
/// user types, LAN discovery on TCP port 9100, the connection state, and the
/// qualification prints used to check a printer that has just been put on the
/// network.
///
/// Takes plain values, not controllers — the `TextEditingController`s stay in
/// the widget layer so this class is testable without any widget machinery.
class NetworkViewModel extends ChangeNotifier {
  /// Creates the view model. Call [start] once mounted to begin observing
  /// connection state and restore the last connected network printer; the
  /// constructor stays side-effect free.
  NetworkViewModel({
    required this._log,
    required this._settings,
    Future<PrintlyDevice?> Function()? loadLastDevice,
    Future<List<PrintlyDevice>> Function({required int port})? discoverPrinters,
    Future<void> Function(PrintlyDevice device)? connectDevice,
    Future<void> Function(PrintlyDevice device)? disconnectDevice,
  }) : _loadLastDevice = loadLastDevice ?? _defaultLoadLastDevice,
       _discoverPrinters = discoverPrinters ?? _defaultDiscoverPrinters,
       _connectDevice = connectDevice ?? _defaultConnectDevice,
       _disconnectDevice = disconnectDevice ?? _defaultDisconnectDevice;

  // Uses the SDK's built-in last-device store while v0.5.0 still carries
  // shared_preferences; v1.0 replaces this with app-owned persistence.
  static Future<PrintlyDevice?> _defaultLoadLastDevice() =>
      // ignore: deprecated_member_use
      Printly.instance.loadLastConnectedDevice();

  static Future<List<PrintlyDevice>> _defaultDiscoverPrinters({
    required int port,
  }) => Printly.instance.discoverNetworkPrinters(port: port);

  static Future<void> _defaultConnectDevice(PrintlyDevice device) =>
      Printly.instance.connect(device);

  static Future<void> _defaultDisconnectDevice(PrintlyDevice device) =>
      Printly.instance.disconnect(device: device);

  /// Default raw-printing port for ESC/POS network printers.
  static const int kDefaultPort = 9100;

  /// Advance the ticket until the notch sits under the printing line.
  ///
  /// One of three commands from Custom's own command set (KPM180H/TK180
  /// command manual 915AH020300700, "Alignment"). They have no standard
  /// ESC/POS equivalent: `GS FF`, the usual "feed to black mark", is answered
  /// with COMMAND ERROR on this firmware.
  ///
  /// Sent only by [alignTicket], never as part of a print job: the TK180
  /// aligns freshly loaded stock by itself and `ESC i` retracts the paper to
  /// the next ticket's top edge, so on already-aligned paper this command
  /// advances a whole ticket and the job comes out as one printed ticket plus
  /// a blank one.
  static const List<int> _alignToPrintHead = <int>[0x1D, 0xF6];

  /// Advance the ticket until the notch sits under the cutting line.
  static const List<int> _alignToCutter = <int>[0x1D, 0xF8];

  /// Total cut. Custom's command manual does not document `GS V` at all —
  /// which is the cut printly emits for [PrintConfig.cutAfterPrint] and
  /// [PrintJob.cut]. The TK180 still cuts on it, but wherever the content
  /// ended rather than on the notch, so the paper is left mid-ticket and every
  /// later job starts misaligned.
  static const List<int> _totalCut = <int>[0x1B, 0x69];

  final ActionLogViewModel _log;
  final SettingsViewModel _settings;
  final Future<PrintlyDevice?> Function() _loadLastDevice;
  final Future<List<PrintlyDevice>> Function({required int port})
  _discoverPrinters;
  final Future<void> Function(PrintlyDevice device) _connectDevice;
  final Future<void> Function(PrintlyDevice device) _disconnectDevice;

  String _host = '';
  int _port = kDefaultPort;
  ConnectionState _state = ConnectionState.disconnected;
  bool _busy = false;
  bool _scanning = false;
  bool _started = false;
  bool _ticketMode = false;
  final List<String> _recents = <String>[];
  final List<PrintlyDevice> _discovered = <PrintlyDevice>[];

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

  /// Whether a LAN discovery sweep is currently running.
  bool get scanning => _scanning;

  /// Addresses connected to earlier in this session (or restored from
  /// persistent storage), most recent first.
  List<String> get recents => UnmodifiableListView<String>(_recents);

  /// Printers found by the most recent [scanNetwork] or failed-[connect] sweep.
  List<PrintlyDevice> get discovered =>
      UnmodifiableListView<PrintlyDevice>(_discovered);

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

  /// Whether [scanNetwork] can run now.
  bool get canScan => !_busy && _state != ConnectionState.connected;

  /// Whether a print can be sent now.
  bool get canPrint => _state == ConnectionState.connected && !_busy;

  /// Whether to end each job with Custom's cut-on-the-notch commands.
  ///
  /// Turn this on for fixed-length pre-notched ticket stock (a Custom TK180
  /// and its kin), where every job has to be cut on a ticket's boundary. Leave
  /// it off for continuous roll paper, where there is no notch to align to and
  /// these commands would simply stall waiting for a mark that never arrives.
  bool get ticketMode => _ticketMode;

  set ticketMode(bool value) {
    if (_ticketMode == value) return;
    _ticketMode = value;
    notifyListeners();
  }

  /// Begins observing the connection state of the current device and restores
  /// the last connected network printer from storage.
  ///
  /// Nothing before this call touches `Printly.instance` — see [_resubscribe].
  void start() {
    _started = true;
    _resubscribe();
    unawaited(restoreLastDevice());
  }

  /// Restores the last connected network printer from persistent storage when
  /// [host] has not been filled in by the user yet.
  Future<void> restoreLastDevice() async {
    try {
      final PrintlyDevice? saved = await _loadLastDevice();
      if (saved == null) return;
      if (!saved.availableTransports.contains(ConnectionType.network)) return;
      _remember(saved.address);
      if (_host.isEmpty) {
        useRecent(saved.address);
      } else {
        notifyListeners();
      }
    } on Object {
      // Storage is best-effort (and unavailable in plain widget tests without
      // a SharedPreferences mock).
    }
  }

  /// Sweeps the local `/24` LAN for printers listening on [port] and populates
  /// [discovered]. When a single printer responds (or [host] is still empty),
  /// its address is filled into [host] and [port] automatically.
  Future<void> scanNetwork() async {
    if (_busy) return;
    _busy = true;
    _scanning = true;
    notifyListeners();
    try {
      final List<PrintlyDevice> found = await _discoverPrinters(port: _port);
      _discovered
        ..clear()
        ..addAll(found);
      if (found.isEmpty) {
        _log.success('network scan → no printers found on port $_port');
      } else {
        final String addresses = found
            .map((PrintlyDevice d) => d.address)
            .join(', ');
        _log.success('network scan → ${found.length} found ($addresses)');
        if (found.length == 1 || _host.isEmpty) {
          useRecent(found.first.address);
        }
      }
    } catch (error) {
      _log.failure('network scan error → $error');
    } finally {
      _scanning = false;
      _busy = false;
      notifyListeners();
    }
  }

  /// Fills [host] and [port] from a `host:port` string in [recents] or
  /// [discovered].
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
  ///
  /// If connecting to [device] fails (for example, the router assigned the
  /// printer a new DHCP lease after a reboot), sweeps the local LAN on [port]
  /// and lists what answered in [discovered] — but never connects to it.
  /// A lone responder on 9100 is not proof it is this counter's printer: the
  /// real one may be powered off or held by another terminal (embedded
  /// Ethernet stacks often accept a single socket), and the responder may be
  /// another counter's printer or a PCL office printer that would print
  /// ESC/POS bytes as garbage. The user confirms by picking it.
  Future<void> connect() async {
    final PrintlyDevice? d = device;
    if (d == null || _busy) return;
    _busy = true;
    notifyListeners();
    try {
      await _connectDevice(d);
      _log.success('network connect → ${d.address}');
      _remember(d.address);
    } catch (error) {
      final int others = await _sweepAfterFailedConnect(d);
      final String hint = others > 0
          ? ' — $others other printer(s) on LAN; verify and pick one from '
                'Discovered'
          : '';
      _log.failure('network connect error → $error$hint');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Refreshes [discovered] after [failed] could not be reached and returns
  /// how many responders other than [failed] were found. Best-effort: a
  /// failed sweep returns 0 and the connect error is reported on its own.
  Future<int> _sweepAfterFailedConnect(PrintlyDevice failed) async {
    _scanning = true;
    notifyListeners();
    try {
      final List<PrintlyDevice> found = await _discoverPrinters(port: _port);
      _discovered
        ..clear()
        ..addAll(found);
      return found
          .where((PrintlyDevice p) => p.address != failed.address)
          .length;
    } on Object {
      return 0;
    } finally {
      _scanning = false;
    }
  }

  /// Closes the TCP connection to the current device.
  Future<void> disconnect() async {
    final PrintlyDevice? d = device;
    if (d == null || _busy) return;
    _busy = true;
    notifyListeners();
    try {
      await _disconnectDevice(d);
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
    final PrintJob job = await newJob(
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
    final PrintJob job = await newJob(
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
        final PrintJob job = await newJob(template.config);
        template.build(job);
        return job;
      });

  /// Creates the job every test prints through.
  ///
  /// In [ticketMode] it drops printly's automatic `GS V` cut, which ignores
  /// the notch (see [_totalCut]). It does not open the
  /// job with the align-to-print-head command; see [_alignToPrintHead].
  Future<PrintJob> newJob(PrintConfig config) => Printly.instance.newJob(
    config: _ticketMode ? ticketJobConfig(config) : config,
  );

  /// Builds the job [alignTicket] sends: the align-to-print-head command on
  /// its own, with no cut and no trailing feed.
  Future<PrintJob> alignTicketJob() async {
    final PrintJob job = await Printly.instance.newJob(
      config: ticketJobConfig(PrintConfig(paperWidth: _settings.paperWidth)),
    );
    return job..raw(_alignToPrintHead);
  }

  /// Feeds the paper to the next ticket's top edge.
  ///
  /// For when the paper is left mid-ticket — after a print with [ticketMode]
  /// off, or a press of the printer's FEED key. Never needed after loading
  /// stock or after a ticket-mode print: the printer is aligned already, and
  /// this would feed one blank ticket.
  Future<void> alignTicket() =>
      _send('align ticket', alignTicketJob, cutOnNotch: false);

  /// Rewrites a roll-paper [config] for notched ticket stock.
  ///
  /// Two of the encoder's finalisers have to go. `cutAfterPrint` emits `GS V`,
  /// which cuts without waiting for the notch. `feedLines` is the subtler one:
  /// [PrintJob.build] appends it *after* the job body, and the body is where
  /// [_send] put the align-to-cutter command and the `ESC i` cut — so the feed
  /// lands after the cut and pushes the paper past the top edge `ESC i` just
  /// retracted it to, and the next job starts mid-ticket. On ticket stock the
  /// alignment command is the only trailing feed a job needs; on roll paper
  /// the original config stays as it is.
  static PrintConfig ticketJobConfig(PrintConfig config) =>
      config.copyWith(cutAfterPrint: false, feedLines: 0);

  /// Shared print plumbing: the connected guard, the busy flag, the log line
  /// and the `finally` that re-enables the buttons however the job ends. Only
  /// [buildJob] differs between the tests — a template fills a job
  /// synchronously, a raster job has to await the engine first — so it stays a
  /// callback instead of being duplicated four times.
  Future<void> _send(
    String label,
    Future<PrintJob> Function() buildJob, {
    bool cutOnNotch = true,
  }) async {
    final PrintlyDevice? d = device;
    if (d == null || !canPrint) return;
    _busy = true;
    notifyListeners();
    try {
      final PrintJob job = await buildJob();
      if (_ticketMode && cutOnNotch) {
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

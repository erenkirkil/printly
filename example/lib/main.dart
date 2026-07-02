import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:printly/printly.dart';

void main() {
  runApp(const PrintlyExampleApp());
}

class PrintlyExampleApp extends StatelessWidget {
  const PrintlyExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'printly example',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const BluetoothPlaygroundPage(),
    );
  }
}

class BluetoothPlaygroundPage extends StatefulWidget {
  const BluetoothPlaygroundPage({super.key});

  @override
  State<BluetoothPlaygroundPage> createState() =>
      _BluetoothPlaygroundPageState();
}

class _BluetoothPlaygroundPageState extends State<BluetoothPlaygroundPage> {
  String _platformVersion = 'Unknown';
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  PrintlyPermissionStatus? _lastPermissionStatus;
  String? _lastAction;

  List<PrintlyDevice> _devices = const <PrintlyDevice>[];
  bool _scanning = false;
  bool _namedOnly = true;
  PrintlyDevice? _activeDevice;
  PrintlyPaperWidth _paperWidth = PrintlyPaperWidth.mm58;

  final TextEditingController _qrController = TextEditingController(
    text: 'https://github.com/erenkirkil/printly',
  );
  final TextEditingController _barcodeController = TextEditingController(
    text: 'PRINTLY123',
  );
  PrintlyBarcodeType _barcodeType = PrintlyBarcodeType.code128;
  PrintlyQrErrorLevel _qrErrorLevel = PrintlyQrErrorLevel.medium;

  /// Scans surface many unnamed BLE beacons/peripherals; printers advertise a
  /// name, so hiding the unnamed noise keeps the list short and the UI smooth.
  List<PrintlyDevice> get _visibleDevices => _namedOnly
      ? _devices
            .where((PrintlyDevice d) => (d.name ?? '').isNotEmpty)
            .toList(growable: false)
      : _devices;

  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  StreamSubscription<List<PrintlyDevice>>? _devicesSub;
  StreamSubscription<bool>? _scanningSub;
  StreamSubscription<PrintlyDevice?>? _activeDeviceSub;

  @override
  void initState() {
    super.initState();
    _loadPlatformVersion();
    _adapterSub = Printly.instance.adapterState.listen((state) {
      if (!mounted) return;
      setState(() => _adapterState = state);
    });
    _devicesSub = Printly.instance.devicesStream.listen((devices) {
      if (!mounted) return;
      setState(() => _devices = devices);
    });
    _scanningSub = Printly.instance.isScanningStream.listen((scanning) {
      if (!mounted) return;
      setState(() => _scanning = scanning);
    });
    _activeDeviceSub = Printly.instance.activeDeviceStream.listen((device) {
      if (!mounted) return;
      setState(() => _activeDevice = device);
    });
  }

  @override
  void dispose() {
    unawaited(_adapterSub?.cancel());
    unawaited(_devicesSub?.cancel());
    unawaited(_scanningSub?.cancel());
    unawaited(_activeDeviceSub?.cancel());
    _qrController.dispose();
    _barcodeController.dispose();
    super.dispose();
  }

  Future<void> _loadPlatformVersion() async {
    String version;
    try {
      version =
          await Printly.instance.getPlatformVersion() ??
          'Unknown platform version';
    } on PlatformException {
      version = 'Failed to get platform version.';
    }
    if (!mounted) return;
    setState(() => _platformVersion = version);
  }

  Future<void> _requestPermissions() async {
    final status = await Printly.instance.requestPermissions();
    if (!mounted) return;
    setState(() {
      _lastPermissionStatus = status;
      _lastAction = 'requestPermissions → ${status.name}';
    });
  }

  Future<void> _openBluetoothSettings() async {
    final opened = await Printly.instance.openBluetoothSettings();
    if (!mounted) return;
    setState(
      () => _lastAction = 'openBluetoothSettings → ${opened ? 'ok' : 'failed'}',
    );
  }

  Future<void> _openAppSettings() async {
    final opened = await Printly.instance.openAppSettings();
    if (!mounted) return;
    setState(
      () => _lastAction = 'openAppSettings → ${opened ? 'ok' : 'failed'}',
    );
  }

  Future<void> _toggleScan() async {
    try {
      if (_scanning) {
        await Printly.instance.stopScan();
        if (!mounted) return;
        setState(() => _lastAction = 'stopScan → ok');
      } else {
        Printly.instance.clearDevices();
        await Printly.instance.startScan();
        if (!mounted) return;
        setState(() => _lastAction = 'startScan → ok');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _lastAction = 'scan error → $error');
    }
  }

  Future<void> _connect(PrintlyDevice device) async {
    try {
      await Printly.instance.connect(device);
      if (!mounted) return;
      setState(() => _lastAction = 'connect → ${device.address}');
    } catch (error) {
      if (!mounted) return;
      setState(() => _lastAction = 'connect error → $error');
    }
  }

  Future<void> _disconnect(PrintlyDevice device) async {
    try {
      await Printly.instance.disconnect(device: device);
      if (!mounted) return;
      setState(() => _lastAction = 'disconnect → ${device.address}');
    } catch (error) {
      if (!mounted) return;
      setState(() => _lastAction = 'disconnect error → $error');
    }
  }

  Future<void> _printTestReceipt() async {
    final device = _activeDevice;
    if (device == null) return;
    try {
      final job = await Printly.instance.newJob(
        config: PrintConfig(
          paperWidth: _paperWidth,
          charset: PrintlyCharset.turkish,
          feedLines: 3,
          cutAfterPrint: true,
        ),
      );
      job
        ..text(
          'PRINTLY MAĞAZA',
          align: PrintlyTextAlign.center,
          style: PrintlyTextStyle.bold,
          size: PrintlyTextSize.doubleHeight,
        )
        ..text('Çağrı Şişli - İstanbul', align: PrintlyTextAlign.center)
        ..divider()
        ..text('Ürün: Türk Kahvesi')
        ..text('Adet: 2 x 45,00 = 90,00 TL')
        ..divider()
        ..text('Teşekkür ederiz!', align: PrintlyTextAlign.center)
        ..feed(1)
        ..qr('https://github.com/erenkirkil/printly')
        ..feed(1)
        ..barcode('590123412345', type: PrintlyBarcodeType.ean13);
      await Printly.instance.print(device, job);
      if (!mounted) return;
      setState(() => _lastAction = 'print → ok');
    } catch (error) {
      if (!mounted) return;
      setState(() => _lastAction = 'print error → $error');
    }
  }

  /// Sweeps every `ESC t n` code page from 0 to 50 and, on each row, prints the
  /// Turkish sample `ğĞşŞıİ` in BOTH CP857 and Windows-1254 byte layouts under
  /// that page. Whichever side renders correctly identifies the printer's
  /// Turkish page and encoding in a single print.
  ///
  /// Each row is preceded by `FS .` (cancel-kanji) so high bytes are treated as
  /// single-byte glyphs — exactly what the real text path does.
  ///
  /// Read the row where one side shows `ğĞşŞıİ` correctly: the number is the
  /// `ESC t` page; the left group means CP857, the right group means W1254.
  Future<void> _printCharsetDiagnostic() async {
    final device = _activeDevice;
    if (device == null) return;
    try {
      final job = await Printly.instance.newJob(
        config: PrintConfig(paperWidth: _paperWidth, feedLines: 4),
      );
      job
        ..text(
          'TR PAGE SWEEP 0-50',
          align: PrintlyTextAlign.center,
          style: PrintlyTextStyle.bold,
        )
        ..text('nNN [CP857] | [W1254]')
        ..divider();

      const String tr = 'ğĞşŞıİ';
      final List<int> cp857 = TurkishCodePage.encode(
        tr,
        charset: PrintlyCharset.turkish,
      );
      final List<int> wpc = TurkishCodePage.encode(
        tr,
        charset: PrintlyCharset.windows1254,
      );
      for (int n = 0; n <= 50; n++) {
        job.raw(<int>[
          0x1B, 0x74, n, // ESC t n (select code page)
          0x1C, 0x2E, // FS . (cancel kanji → single-byte glyphs)
          ...'n$n '.codeUnits,
          ...cp857,
          ...' | '.codeUnits,
          ...wpc,
          0x0A,
        ]);
      }
      job.raw(<int>[0x1B, 0x74, 0x00]); // restore the default page

      await Printly.instance.print(device, job);
      if (!mounted) return;
      setState(() => _lastAction = 'page sweep → ok');
    } catch (error) {
      if (!mounted) return;
      setState(() => _lastAction = 'page sweep error → $error');
    }
  }

  void _setAction(String action) {
    if (!mounted) return;
    setState(() => _lastAction = action);
  }

  /// Prints the QR-field content at the selected error level, with the byte
  /// count above the symbol. The module size is chosen automatically from the
  /// payload length + error level, so a longer string yields a denser QR.
  Future<void> _printCustomQr() async {
    final device = _activeDevice;
    if (device == null) return;
    final String data = _qrController.text;
    try {
      final job = await Printly.instance.newJob(
        config: PrintConfig(
          paperWidth: _paperWidth,
          feedLines: 3,
          cutAfterPrint: true,
        ),
      );
      job
        ..text(
          'QR TEST',
          align: PrintlyTextAlign.center,
          style: PrintlyTextStyle.bold,
        )
        ..text(
          '${data.length} chars · EC ${_qrErrorLevel.name}',
          align: PrintlyTextAlign.center,
        )
        ..feed(1)
        ..qr(data, errorLevel: _qrErrorLevel)
        ..feed(1)
        ..text(
          data,
          align: PrintlyTextAlign.center,
          charset: PrintlyCharset.latin,
        );
      await Printly.instance.print(device, job);
      _setAction('qr → ok (${data.length} chars)');
    } catch (error) {
      _setAction('qr error → $error');
    }
  }

  /// Prints three QR codes of growing payload length on one strip so the
  /// module-density scaling is visible side by side on the paper.
  Future<void> _printQrDensityDemo() async {
    final device = _activeDevice;
    if (device == null) return;
    const List<String> payloads = <String>[
      'PRINTLY',
      'https://github.com/erenkirkil/printly',
      'https://printly.example.com/receipt?id=1234567890&store=istanbul'
          '&items=coffee,water,cake&total=95.50&ts=2026-07-01T15:56:00'
          '&sig=abcdef0123456789abcdef0123456789',
    ];
    try {
      final job = await Printly.instance.newJob(
        config: PrintConfig(
          paperWidth: _paperWidth,
          feedLines: 3,
          cutAfterPrint: true,
        ),
      );
      job.text(
        'QR DENSITY DEMO',
        align: PrintlyTextAlign.center,
        style: PrintlyTextStyle.bold,
      );
      for (final String payload in payloads) {
        job
          ..divider()
          ..text('${payload.length} chars', align: PrintlyTextAlign.center)
          ..qr(payload)
          ..feed(1);
      }
      await Printly.instance.print(device, job);
      _setAction('qr density → ok');
    } catch (error) {
      _setAction('qr density error → $error');
    }
  }

  /// Prints the barcode field with the selected symbology. Invalid payloads
  /// (e.g. letters in an EAN-13) throw [ArgumentError], surfaced in Last action.
  Future<void> _printCustomBarcode() async {
    final device = _activeDevice;
    if (device == null) return;
    final String data = _barcodeController.text;
    try {
      final job = await Printly.instance.newJob(
        config: PrintConfig(
          paperWidth: _paperWidth,
          feedLines: 3,
          cutAfterPrint: true,
        ),
      );
      job
        ..text(
          'BARCODE TEST',
          align: PrintlyTextAlign.center,
          style: PrintlyTextStyle.bold,
        )
        ..text(
          '${_barcodeType.name} · ${data.length} chars',
          align: PrintlyTextAlign.center,
        )
        ..feed(1)
        ..barcode(data, type: _barcodeType, height: 80, width: 2)
        ..feed(1);
      await Printly.instance.print(device, job);
      _setAction('barcode → ok (${_barcodeType.name})');
    } catch (error) {
      _setAction('barcode error → $error');
    }
  }

  /// Prints one valid sample per supported symbology so the whole barcode
  /// catalogue can be eyeballed on a single strip.
  Future<void> _printBarcodeGallery() async {
    final device = _activeDevice;
    if (device == null) return;
    const List<(PrintlyBarcodeType, String)> samples =
        <(PrintlyBarcodeType, String)>[
          (PrintlyBarcodeType.ean13, '590123412345'),
          (PrintlyBarcodeType.ean8, '1234567'),
          (PrintlyBarcodeType.upcA, '01234567890'),
          (PrintlyBarcodeType.code39, 'CODE-39'),
          (PrintlyBarcodeType.code128, 'PRINTLY'),
          (PrintlyBarcodeType.itf, '12345678'),
          (PrintlyBarcodeType.codabar, 'A12345B'),
        ];
    try {
      final job = await Printly.instance.newJob(
        config: PrintConfig(
          paperWidth: _paperWidth,
          feedLines: 3,
          cutAfterPrint: true,
        ),
      );
      job.text(
        'BARCODE GALLERY',
        align: PrintlyTextAlign.center,
        style: PrintlyTextStyle.bold,
      );
      for (final (PrintlyBarcodeType type, String data) in samples) {
        job
          ..divider()
          ..text('${type.name}: $data', align: PrintlyTextAlign.center)
          ..barcode(data, type: type, height: 70, width: 2)
          ..feed(1);
      }
      await Printly.instance.print(device, job);
      _setAction('barcode gallery → ok');
    } catch (error) {
      _setAction('barcode gallery error → $error');
    }
  }

  /// Prints an ASCII layout probe: every alignment, size and emphasis, a
  /// right-aligned numeric price column, and a per-column ruler — pure ASCII so
  /// it renders correctly even on a CP437-only printer and validates the paper
  /// geometry (columns per line, alignment, magnification).
  Future<void> _printLayoutSample() async {
    final device = _activeDevice;
    if (device == null) return;
    final int cpl = _paperWidth.maxCharsPerLine;
    final String ruler = List<String>.generate(
      cpl,
      (int i) => '${(i + 1) % 10}',
    ).join();
    try {
      final job = await Printly.instance.newJob(
        config: PrintConfig(
          paperWidth: _paperWidth,
          charset: PrintlyCharset.latin,
          feedLines: 3,
          cutAfterPrint: true,
        ),
      );
      job
        ..text(
          'LAYOUT & RULER',
          align: PrintlyTextAlign.center,
          style: PrintlyTextStyle.bold,
          size: PrintlyTextSize.doubleHeight,
        )
        ..text(
          '$cpl cols · ${_paperWidth.dots} dots',
          align: PrintlyTextAlign.center,
        )
        ..divider()
        ..text('Left', align: PrintlyTextAlign.left)
        ..text('Center', align: PrintlyTextAlign.center)
        ..text('Right', align: PrintlyTextAlign.right)
        ..divider()
        ..text('Normal 1x1')
        ..text('Double width', size: PrintlyTextSize.doubleWidth)
        ..text('Double height', size: PrintlyTextSize.doubleHeight)
        ..text('Double W+H', size: PrintlyTextSize.doubleWidthHeight)
        ..divider()
        ..text('Bold', style: PrintlyTextStyle.bold)
        ..text('Underline', style: PrintlyTextStyle.underline)
        ..text('Bold + Underline', style: PrintlyTextStyle.boldUnderline)
        ..divider()
        ..text(_priceRow('Coffee x2', '90.00', cpl))
        ..text(_priceRow('Water', '5.50', cpl))
        ..text(_priceRow('TOTAL', '95.50', cpl), style: PrintlyTextStyle.bold)
        ..divider()
        ..text('Column ruler:')
        ..text(ruler);
      await Printly.instance.print(device, job);
      _setAction('layout → ok');
    } catch (error) {
      _setAction('layout error → $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('printly playground')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _InfoCard(label: 'Platform', value: _platformVersion),
            const SizedBox(height: 12),
            _InfoCard(
              label: 'Adapter state',
              value: _adapterState.name,
              trailing: Icon(
                _adapterState == BluetoothAdapterState.poweredOn
                    ? Icons.bluetooth_connected
                    : Icons.bluetooth_disabled,
              ),
            ),
            const SizedBox(height: 12),
            _InfoCard(
              label: 'Active device',
              value: _activeDevice?.name ?? _activeDevice?.address ?? 'none',
              trailing: Icon(
                _activeDevice != null ? Icons.print : Icons.print_disabled,
              ),
            ),
            const SizedBox(height: 12),
            if (_lastPermissionStatus != null)
              _InfoCard(
                label: 'Last permission status',
                value: _lastPermissionStatus!.name,
              ),
            if (_lastAction != null) ...[
              const SizedBox(height: 12),
              _InfoCard(label: 'Last action', value: _lastAction!),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _requestPermissions,
              icon: const Icon(Icons.lock_open),
              label: const Text('Request Bluetooth permissions'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _openBluetoothSettings,
                    icon: const Icon(Icons.bluetooth),
                    label: const Text('Bluetooth settings'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _openAppSettings,
                    icon: const Icon(Icons.settings),
                    label: const Text('App settings'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _toggleScan,
              icon: Icon(_scanning ? Icons.stop : Icons.search),
              label: Text(_scanning ? 'Stop scan' : 'Start scan'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _namedOnly,
              onChanged: (bool v) => setState(() => _namedOnly = v),
              title: const Text('Named devices only'),
              subtitle: Text(
                'Showing ${_visibleDevices.length} of ${_devices.length}',
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<PrintlyPaperWidth>(
                segments: const <ButtonSegment<PrintlyPaperWidth>>[
                  ButtonSegment<PrintlyPaperWidth>(
                    value: PrintlyPaperWidth.mm58,
                    label: Text('58 mm'),
                  ),
                  ButtonSegment<PrintlyPaperWidth>(
                    value: PrintlyPaperWidth.mm80,
                    label: Text('80 mm'),
                  ),
                ],
                selected: <PrintlyPaperWidth>{_paperWidth},
                onSelectionChanged: (Set<PrintlyPaperWidth> selection) {
                  setState(() => _paperWidth = selection.first);
                },
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _activeDevice == null ? null : _printTestReceipt,
              icon: const Icon(Icons.receipt_long),
              label: const Text('Print Turkish test receipt'),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: _activeDevice == null ? null : _printCharsetDiagnostic,
              icon: const Icon(Icons.troubleshoot),
              label: const Text('Print charset diagnostic'),
            ),
            const SizedBox(height: 12),
            _PrintLabSection(
              enabled: _activeDevice != null,
              qrController: _qrController,
              barcodeController: _barcodeController,
              barcodeType: _barcodeType,
              qrErrorLevel: _qrErrorLevel,
              onBarcodeTypeChanged: (PrintlyBarcodeType t) =>
                  setState(() => _barcodeType = t),
              onQrErrorLevelChanged: (PrintlyQrErrorLevel l) =>
                  setState(() => _qrErrorLevel = l),
              onPrintQr: _printCustomQr,
              onPrintQrDensity: _printQrDensityDemo,
              onPrintBarcode: _printCustomBarcode,
              onPrintBarcodeGallery: _printBarcodeGallery,
              onPrintLayout: _printLayoutSample,
            ),
            const SizedBox(height: 16),
            _DevicesSection(
              devices: _visibleDevices,
              activeDevice: _activeDevice,
              scanning: _scanning,
              onConnect: _connect,
              onDisconnect: _disconnect,
            ),
          ],
        ),
      ),
    );
  }
}

class _DevicesSection extends StatelessWidget {
  const _DevicesSection({
    required this.devices,
    required this.activeDevice,
    required this.scanning,
    required this.onConnect,
    required this.onDisconnect,
  });

  final List<PrintlyDevice> devices;
  final PrintlyDevice? activeDevice;
  final bool scanning;
  final ValueChanged<PrintlyDevice> onConnect;
  final ValueChanged<PrintlyDevice> onDisconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('Discovered devices', style: theme.textTheme.titleMedium),
            const SizedBox(width: 8),
            if (scanning)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            const Spacer(),
            Text('${devices.length}', style: theme.textTheme.labelMedium),
          ],
        ),
        const SizedBox(height: 8),
        if (devices.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              scanning
                  ? 'Scanning…'
                  : 'No devices yet. Tap “Start scan” to begin.',
              style: theme.textTheme.bodyMedium,
            ),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: devices.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final device = devices[index];
              final isActive = activeDevice?.dedupKey == device.dedupKey;
              return _DeviceTile(
                device: device,
                isActive: isActive,
                onConnect: () => onConnect(device),
                onDisconnect: () => onDisconnect(device),
              );
            },
          ),
      ],
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.device,
    required this.isActive,
    required this.onConnect,
    required this.onDisconnect,
  });

  final PrintlyDevice device;
  final bool isActive;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<ConnectionState>(
      stream: Printly.instance.connectionStateOf(device),
      initialData: Printly.instance.connectionStateSnapshotOf(device),
      builder: (context, snapshot) {
        final state = snapshot.data ?? ConnectionState.disconnected;
        final busy =
            state == ConnectionState.connecting ||
            state == ConnectionState.disconnecting ||
            state == ConnectionState.reconnecting;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(
                  device.type == ConnectionType.ble
                      ? Icons.bluetooth
                      : device.type == ConnectionType.classic
                      ? Icons.bluetooth_searching
                      : Icons.lan,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device.name ?? '(unnamed)',
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(device.address, style: theme.textTheme.bodySmall),
                      const SizedBox(height: 2),
                      Text(
                        [
                          device.type.name,
                          if (device.rssi != null) '${device.rssi} dBm',
                          if (device.isBonded) 'bonded',
                          state.name,
                        ].join(' · '),
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (busy)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      if (state == ConnectionState.connecting ||
                          state == ConnectionState.reconnecting) ...[
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: onDisconnect,
                          child: const Text('Cancel'),
                        ),
                      ],
                    ],
                  )
                else if (isActive || state == ConnectionState.connected)
                  TextButton(
                    onPressed: onDisconnect,
                    child: const Text('Disconnect'),
                  )
                else
                  FilledButton(
                    onPressed: onConnect,
                    child: const Text('Connect'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Pads [left] and [right] to fill [width] columns with the value flush right —
/// a receipt "label        value" row. Falls back to a single space when the
/// two strings already exceed the line.
String _priceRow(String left, String right, int width) {
  final int gap = width - left.length - right.length;
  if (gap < 1) return '$left $right';
  return '$left${' ' * gap}$right';
}

/// Playground controls for exercising the print API: QR, barcode and a text
/// layout probe. All actions are disabled until a device is connected.
class _PrintLabSection extends StatelessWidget {
  const _PrintLabSection({
    required this.enabled,
    required this.qrController,
    required this.barcodeController,
    required this.barcodeType,
    required this.qrErrorLevel,
    required this.onBarcodeTypeChanged,
    required this.onQrErrorLevelChanged,
    required this.onPrintQr,
    required this.onPrintQrDensity,
    required this.onPrintBarcode,
    required this.onPrintBarcodeGallery,
    required this.onPrintLayout,
  });

  final bool enabled;
  final TextEditingController qrController;
  final TextEditingController barcodeController;
  final PrintlyBarcodeType barcodeType;
  final PrintlyQrErrorLevel qrErrorLevel;
  final ValueChanged<PrintlyBarcodeType> onBarcodeTypeChanged;
  final ValueChanged<PrintlyQrErrorLevel> onQrErrorLevelChanged;
  final VoidCallback onPrintQr;
  final VoidCallback onPrintQrDensity;
  final VoidCallback onPrintBarcode;
  final VoidCallback onPrintBarcodeGallery;
  final VoidCallback onPrintLayout;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Print lab', style: theme.textTheme.titleMedium),
            if (!enabled)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Connect a device to enable printing.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 12),

            // ── QR ──────────────────────────────────────────────────────────
            Text('QR code', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            TextField(
              controller: qrController,
              decoration: const InputDecoration(
                labelText: 'QR content (Latin-1)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButton<PrintlyQrErrorLevel>(
                    isExpanded: true,
                    value: qrErrorLevel,
                    items: [
                      for (final PrintlyQrErrorLevel l
                          in PrintlyQrErrorLevel.values)
                        DropdownMenuItem<PrintlyQrErrorLevel>(
                          value: l,
                          child: Text('EC ${l.name}'),
                        ),
                    ],
                    onChanged: enabled
                        ? (PrintlyQrErrorLevel? v) {
                            if (v != null) onQrErrorLevelChanged(v);
                          }
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: enabled ? onPrintQr : null,
                  child: const Text('Print QR'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: enabled ? onPrintQrDensity : null,
              icon: const Icon(Icons.grid_on),
              label: const Text('Print QR density demo'),
            ),
            const Divider(height: 24),

            // ── Barcode ─────────────────────────────────────────────────────
            Text('Barcode', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            TextField(
              controller: barcodeController,
              decoration: const InputDecoration(
                labelText: 'Barcode payload',
                helperText: 'Long codes may overflow 58 mm at this bar width',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButton<PrintlyBarcodeType>(
                    isExpanded: true,
                    value: barcodeType,
                    items: [
                      for (final PrintlyBarcodeType t
                          in PrintlyBarcodeType.values)
                        DropdownMenuItem<PrintlyBarcodeType>(
                          value: t,
                          child: Text(t.name),
                        ),
                    ],
                    onChanged: enabled
                        ? (PrintlyBarcodeType? v) {
                            if (v != null) onBarcodeTypeChanged(v);
                          }
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: enabled ? onPrintBarcode : null,
                  child: const Text('Print'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: enabled ? onPrintBarcodeGallery : null,
              icon: const Icon(Icons.view_list),
              label: const Text('Print all symbologies'),
            ),
            const Divider(height: 24),

            // ── Text layout ─────────────────────────────────────────────────
            Text('Text layout', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: enabled ? onPrintLayout : null,
              icon: const Icon(Icons.straighten),
              label: const Text('Print layout & ruler sample'),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.label, required this.value, this.trailing});

  final String label;
  final String value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: theme.textTheme.labelMedium),
                  const SizedBox(height: 4),
                  Text(value, style: theme.textTheme.titleMedium),
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

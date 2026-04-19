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
  PermissionStatus? _lastPermissionStatus;
  String? _lastAction;

  List<PrintlyDevice> _devices = const <PrintlyDevice>[];
  bool _scanning = false;
  PrintlyDevice? _activeDevice;

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
            const SizedBox(height: 16),
            _DevicesSection(
              devices: _devices,
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
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
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

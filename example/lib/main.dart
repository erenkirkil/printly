import 'dart:async';

import 'package:flutter/material.dart';
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
  StreamSubscription<BluetoothAdapterState>? _adapterSub;

  @override
  void initState() {
    super.initState();
    _loadPlatformVersion();
    _adapterSub = Printly.instance.adapterState.listen((state) {
      if (!mounted) return;
      setState(() => _adapterState = state);
    });
  }

  @override
  void dispose() {
    unawaited(_adapterSub?.cancel());
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('printly — sprint 2 playground')),
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
            FilledButton.tonalIcon(
              onPressed: _openBluetoothSettings,
              icon: const Icon(Icons.bluetooth),
              label: const Text('Open Bluetooth settings'),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: _openAppSettings,
              icon: const Icon(Icons.settings),
              label: const Text('Open app settings'),
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

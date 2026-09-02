import 'dart:async';

import 'package:flutter/material.dart';

import '../viewmodel/action_log_view_model.dart';
import '../viewmodel/bluetooth_view_model.dart';
import '../viewmodel/network_view_model.dart';
import '../viewmodel/print_view_model.dart';
import '../viewmodel/raster_view_model.dart';
import '../viewmodel/scan_view_model.dart';
import '../viewmodel/settings_view_model.dart';
import 'network_tab.dart';
import 'print_tab.dart';
import 'scan_tab.dart';
import 'settings_tab.dart';
import 'widgets/status_strip.dart';

/// Owns every view model and wires them to the four tabs.
///
/// Dependencies are passed through constructors rather than a DI container:
/// [SettingsViewModel] holds the paper width and is handed to
/// [PrintViewModel], so a change on the Settings tab is immediately reflected
/// in the jobs the Print tab builds.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late final ActionLogViewModel _log;
  late final SettingsViewModel _settings;
  late final BluetoothViewModel _bluetooth;
  late final ScanViewModel _scan;
  late final NetworkViewModel _network;
  late final PrintViewModel _print;
  late final RasterViewModel _raster;

  int _index = 0;

  @override
  void initState() {
    super.initState();
    _log = ActionLogViewModel();
    _settings = SettingsViewModel();
    _bluetooth = BluetoothViewModel(log: _log);
    _scan = ScanViewModel(log: _log);
    _network = NetworkViewModel(log: _log, settings: _settings);
    _print = PrintViewModel(log: _log, settings: _settings);
    _raster = RasterViewModel(log: _log, settings: _settings);

    // Subscriptions and platform calls start here, never in the constructors:
    // constructing a view model must stay side-effect free so it can be built
    // in a test without a live method channel.
    _bluetooth.start();
    _scan.start();
    _network.start();
    _print.start();
    _raster.start();
    unawaited(_settings.start());
  }

  @override
  void dispose() {
    _raster.dispose();
    _print.dispose();
    _scan.dispose();
    _network.dispose();
    _bluetooth.dispose();
    _settings.dispose();
    _log.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('printly playground')),
      body: Column(
        children: <Widget>[
          ListenableBuilder(
            listenable: _log,
            builder: (BuildContext context, _) => StatusStrip(
              log: _log.last,
              history: _log.entries,
              onClear: _log.clear,
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: _index,
              children: <Widget>[
                ScanTab(scan: _scan, bluetooth: _bluetooth),
                NetworkTab(vm: _network, settings: _settings),
                PrintTab(vm: _print, raster: _raster),
                SettingsTab(settings: _settings, bluetooth: _bluetooth),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (int i) {
          // Leaving Scan stops the scan. Nobody is watching the list, and the
          // radio keeps costing battery until something says otherwise.
          if (_index == 0 && i != 0) {
            unawaited(_scan.stopScanIfRunning());
          }
          setState(() => _index = i);
        },
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.bluetooth_searching),
            label: 'Scan',
          ),
          NavigationDestination(icon: Icon(Icons.lan), label: 'Network'),
          NavigationDestination(icon: Icon(Icons.print), label: 'Print'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}

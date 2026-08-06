import 'package:flutter/material.dart';

import '../viewmodel/bluetooth_view_model.dart';
import '../viewmodel/scan_view_model.dart';
import 'widgets/devices_list.dart';
import 'widgets/info_card.dart';

/// Discovery: adapter state, the scan toggle and the device list.
class ScanTab extends StatelessWidget {
  const ScanTab({required this.scan, required this.bluetooth, super.key});

  final ScanViewModel scan;
  final BluetoothViewModel bluetooth;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[scan, bluetooth]),
      builder: (BuildContext context, _) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            InfoCard(
              label: 'Adapter state',
              value: bluetooth.adapterState.name,
              trailing: Icon(
                bluetooth.isPoweredOn
                    ? Icons.bluetooth_connected
                    : Icons.bluetooth_disabled,
              ),
            ),
            const SizedBox(height: 12),
            InfoCard(
              label: 'Active device',
              value:
                  scan.activeDevice?.name ??
                  scan.activeDevice?.address ??
                  'none',
              trailing: Icon(
                scan.activeDevice != null ? Icons.print : Icons.print_disabled,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: scan.toggleScan,
              icon: Icon(scan.scanning ? Icons.stop : Icons.search),
              label: Text(scan.scanning ? 'Stop scan' : 'Start scan'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: scan.namedOnly,
              onChanged: (bool v) => scan.namedOnly = v,
              title: const Text('Named devices only'),
              subtitle: Text(
                'Showing ${scan.visibleDevices.length} of '
                '${scan.devices.length} · filters natively from the '
                'next scan',
              ),
            ),
            const SizedBox(height: 16),
            DevicesList(
              devices: scan.visibleDevices,
              activeDevice: scan.activeDevice,
              scanning: scan.scanning,
              onConnect: scan.connect,
              onDisconnect: scan.disconnect,
            ),
          ],
        );
      },
    );
  }
}

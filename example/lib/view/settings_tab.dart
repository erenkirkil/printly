import 'package:flutter/material.dart';
import 'package:printly/printly.dart';

import '../viewmodel/bluetooth_view_model.dart';
import '../viewmodel/settings_view_model.dart';
import 'widgets/info_card.dart';

/// Permissions, OS settings shortcuts and the paper-width selector that every
/// print job on the Print tab reads.
class SettingsTab extends StatelessWidget {
  const SettingsTab({
    required this.settings,
    required this.bluetooth,
    super.key,
  });

  final SettingsViewModel settings;
  final BluetoothViewModel bluetooth;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[settings, bluetooth]),
      builder: (BuildContext context, _) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            InfoCard(label: 'Platform', value: settings.platformVersion),
            if (bluetooth.lastPermissionStatus != null) ...<Widget>[
              const SizedBox(height: 12),
              InfoCard(
                label: 'Last permission status',
                value: bluetooth.lastPermissionStatus!.name,
              ),
            ],
            const SizedBox(height: 24),
            Text('Paper width', style: theme.textTheme.labelLarge),
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
                selected: <PrintlyPaperWidth>{settings.paperWidth},
                onSelectionChanged: (Set<PrintlyPaperWidth> selection) {
                  settings.paperWidth = selection.first;
                },
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${settings.paperWidth.dots} dots · '
              '${settings.paperWidth.maxCharsPerLine} cols',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            Text('Permissions', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: bluetooth.requestPermissions,
              icon: const Icon(Icons.lock_open),
              label: const Text('Request Bluetooth permissions'),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: bluetooth.isPoweredOn
                  ? null
                  : bluetooth.requestEnableBluetooth,
              icon: const Icon(Icons.bluetooth_disabled),
              label: const Text('Turn on Bluetooth'),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: bluetooth.openBluetoothSettings,
                    icon: const Icon(Icons.bluetooth),
                    label: const Text('Bluetooth settings'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: bluetooth.openAppSettings,
                    icon: const Icon(Icons.settings),
                    label: const Text('App settings'),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

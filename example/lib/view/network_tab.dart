import 'package:flutter/material.dart';

import '../viewmodel/network_view_model.dart';
import '../viewmodel/settings_view_model.dart';
import 'widgets/network_connect_card.dart';

/// Everything a network (Ethernet/Wi-Fi) printer needs in one screen: the
/// address, LAN discovery on TCP port 9100, the connection, and the prints
/// used to qualify a new device.
class NetworkTab extends StatelessWidget {
  const NetworkTab({required this.vm, required this.settings, super.key});

  final NetworkViewModel vm;
  final SettingsViewModel settings;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[vm, settings]),
      builder: (BuildContext context, _) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            NetworkConnectCard(vm: vm),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: vm.ticketMode,
              onChanged: (bool v) => vm.ticketMode = v,
              title: const Text('Ticket mode (notched stock)'),
              subtitle: const Text(
                'Aligns each job to the ticket notch and cuts on the boundary '
                'with Custom\'s ESC i. Leave off for continuous roll paper.',
              ),
            ),
            const SizedBox(height: 12),
            Text('Test prints', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Paper width comes from the Settings tab '
              '(${settings.paperWidth.dots} dots). Turkish here goes through '
              'the raster path (GS v 0); the code-page (CP857) variant of the '
              'same receipt is on the Print tab.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                FilledButton.tonalIcon(
                  onPressed: vm.canPrint ? vm.printTextTest : null,
                  icon: const Icon(Icons.text_fields),
                  label: const Text('Text + layout'),
                ),
                FilledButton.tonalIcon(
                  onPressed: vm.canPrint ? vm.printTurkishRaster : null,
                  icon: const Icon(Icons.translate),
                  label: const Text('Turkish (raster)'),
                ),
                FilledButton.tonalIcon(
                  onPressed: vm.canPrint ? vm.printQrTest : null,
                  icon: const Icon(Icons.qr_code_2),
                  label: const Text('QR'),
                ),
                FilledButton.tonalIcon(
                  onPressed: vm.canPrint ? vm.printCutTest : null,
                  icon: const Icon(Icons.content_cut),
                  label: const Text('Cut'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('Setup notes', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    Text(
                      'The printer must be reachable from this device on the '
                      'same LAN. "Scan LAN" sweeps the local /24 subnet on '
                      'TCP port 9100 with a zero-write handshake (~1.2 s). If '
                      'a saved DHCP IP goes stale after moving the printer or '
                      'rebooting the router, "Connect" automatically re-scans '
                      'the LAN and switches to the new IP when a single '
                      'printer responds.',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Android needs android.permission.INTERNET in the app '
                      'manifest. iOS needs NSLocalNetworkUsageDescription in '
                      'Info.plist — without it the local-network prompt never '
                      'appears and the connect fails. Both are declared in '
                      'this example.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

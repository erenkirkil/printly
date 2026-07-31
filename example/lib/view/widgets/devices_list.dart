import 'package:flutter/material.dart' hide ConnectionState;
import 'package:printly/printly.dart';

import 'device_tile.dart';

/// The discovered-device list with its header and empty state.
class DevicesList extends StatelessWidget {
  const DevicesList({
    required this.devices,
    required this.activeDevice,
    required this.scanning,
    required this.onConnect,
    required this.onDisconnect,
    super.key,
  });

  final List<PrintlyDevice> devices;
  final PrintlyDevice? activeDevice;
  final bool scanning;
  final ValueChanged<PrintlyDevice> onConnect;
  final ValueChanged<PrintlyDevice> onDisconnect;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
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
            itemBuilder: (BuildContext context, int index) {
              final PrintlyDevice device = devices[index];
              return DeviceTile(
                device: device,
                isActive: activeDevice?.dedupKey == device.dedupKey,
                onConnect: () => onConnect(device),
                onDisconnect: () => onDisconnect(device),
              );
            },
          ),
      ],
    );
  }
}

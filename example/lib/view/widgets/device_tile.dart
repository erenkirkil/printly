import 'package:flutter/material.dart' hide ConnectionState;
import 'package:printly/printly.dart';

/// One discovered device, with its live connection state and the matching
/// connect / cancel / disconnect affordance.
class DeviceTile extends StatelessWidget {
  const DeviceTile({
    required this.device,
    required this.isActive,
    required this.onConnect,
    required this.onDisconnect,
    super.key,
  });

  final PrintlyDevice device;
  final bool isActive;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return StreamBuilder<ConnectionState>(
      stream: Printly.instance.connectionStateOf(device),
      initialData: Printly.instance.connectionStateSnapshotOf(device),
      builder: (BuildContext context, AsyncSnapshot<ConnectionState> snapshot) {
        final ConnectionState state =
            snapshot.data ?? ConnectionState.disconnected;
        final bool busy =
            state == ConnectionState.connecting ||
            state == ConnectionState.disconnecting ||
            state == ConnectionState.reconnecting;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: <Widget>[
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
                    children: <Widget>[
                      Text(
                        device.name ?? '(unnamed)',
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(device.address, style: theme.textTheme.bodySmall),
                      const SizedBox(height: 2),
                      Text(
                        <String>[
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
                    children: <Widget>[
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      if (state == ConnectionState.connecting ||
                          state == ConnectionState.reconnecting) ...<Widget>[
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

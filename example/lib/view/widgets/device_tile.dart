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
                Icon(_iconFor(device.availableTransports)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        device.hasName ? device.name! : '(unnamed)',
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(device.address, style: theme.textTheme.bodySmall),
                      const SizedBox(height: 2),
                      Text(
                        <String>[
                          _labelFor(device.availableTransports),
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

  /// Picks a representative icon for [transports] based on what the radio
  /// advertises, not on which one `connect()` will actually pick — that
  /// preference is platform-specific (Android prefers Classic for dual-mode
  /// printers, iOS only ever uses BLE; see `ConnectionController.
  /// resolveTransport`). A dual-mode radio (Classic + BLE) is shown with the
  /// BLE glyph purely because BLE is checked first here; the combined
  /// `classic+ble` text label from [_labelFor] is what actually distinguishes
  /// dual-mode devices in the UI.
  static IconData _iconFor(Set<ConnectionType> transports) {
    if (transports.contains(ConnectionType.ble)) return Icons.bluetooth;
    if (transports.contains(ConnectionType.classic)) {
      return Icons.bluetooth_searching;
    }
    return Icons.lan;
  }

  /// Human-readable transport label. A dual-mode printer gets a combined
  /// label (`classic+ble`) instead of picking just one, since both were
  /// actually observed.
  static String _labelFor(Set<ConnectionType> transports) {
    if (transports.length > 1) {
      final List<String> sorted =
          transports.map((ConnectionType t) => t.name).toList()..sort();
      return sorted.join('+');
    }
    return transports.single.name;
  }
}

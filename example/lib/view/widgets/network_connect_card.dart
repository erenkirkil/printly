import 'package:flutter/material.dart' hide ConnectionState;
import 'package:printly/printly.dart';

import '../../viewmodel/network_view_model.dart';

/// Address entry, connect/disconnect and the live connection state for a
/// network printer. Owns the text controllers so the view model stays free of
/// widget types.
class NetworkConnectCard extends StatefulWidget {
  const NetworkConnectCard({required this.vm, super.key});

  final NetworkViewModel vm;

  @override
  State<NetworkConnectCard> createState() => _NetworkConnectCardState();
}

class _NetworkConnectCardState extends State<NetworkConnectCard> {
  late final TextEditingController _host;
  late final TextEditingController _port;

  @override
  void initState() {
    super.initState();
    _host = TextEditingController(text: widget.vm.host);
    _port = TextEditingController(text: '${widget.vm.port}');
    widget.vm.addListener(_syncFromViewModel);
  }

  /// `useRecent` changes host/port from outside the fields; mirror that back
  /// into the controllers without fighting the user's cursor while typing.
  void _syncFromViewModel() {
    if (_host.text != widget.vm.host) _host.text = widget.vm.host;
    final String p = '${widget.vm.port}';
    if (_port.text != p) _port.text = p;
  }

  @override
  void dispose() {
    widget.vm.removeListener(_syncFromViewModel);
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final NetworkViewModel vm = widget.vm;
    final bool connected = vm.state == ConnectionState.connected;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text('Printer address', style: theme.textTheme.titleMedium),
                const Spacer(),
                Chip(
                  avatar: Icon(
                    connected ? Icons.lan : Icons.lan_outlined,
                    size: 18,
                  ),
                  label: Text(vm.state.name),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _host,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enabled: !connected,
                    decoration: const InputDecoration(
                      labelText: 'Host / IP',
                      hintText: '192.168.0.5',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (String value) => vm.host = value,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _port,
                    keyboardType: TextInputType.number,
                    enabled: !connected,
                    decoration: const InputDecoration(
                      labelText: 'Port',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (String value) => vm.port =
                        int.tryParse(value.trim()) ??
                        NetworkViewModel.kDefaultPort,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    onPressed: vm.canConnect ? vm.connect : null,
                    icon: const Icon(Icons.link),
                    label: const Text('Connect'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: connected && !vm.busy ? vm.disconnect : null,
                    icon: const Icon(Icons.link_off),
                    label: const Text('Disconnect'),
                  ),
                ),
              ],
            ),
            if (vm.recents.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text('Recent', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: vm.recents
                    .map(
                      (String address) => ActionChip(
                        label: Text(address),
                        onPressed: connected
                            ? null
                            : () => vm.useRecent(address),
                      ),
                    )
                    .toList(growable: false),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

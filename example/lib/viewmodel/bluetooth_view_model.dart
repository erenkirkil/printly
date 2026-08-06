import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:printly/printly.dart';

import 'action_log_view_model.dart';

/// Adapter state, runtime permissions and the OS settings shortcuts.
class BluetoothViewModel extends ChangeNotifier {
  BluetoothViewModel({required ActionLogViewModel log}) : _log = log;

  final ActionLogViewModel _log;

  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  PrintlyPermissionStatus? _lastPermissionStatus;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;

  BluetoothAdapterState get adapterState => _adapterState;
  PrintlyPermissionStatus? get lastPermissionStatus => _lastPermissionStatus;
  bool get isPoweredOn => _adapterState == BluetoothAdapterState.poweredOn;

  /// Subscribes to the adapter stream. On iOS the first subscriber is also what
  /// triggers the system Bluetooth prompt, so this runs from the widget's
  /// `initState` rather than at construction.
  void start() {
    _adapterSub = Printly.instance.adapterState.listen((
      BluetoothAdapterState state,
    ) {
      _adapterState = state;
      notifyListeners();
    });
  }

  Future<void> requestPermissions() async {
    final PrintlyPermissionStatus status = await Printly.instance
        .requestPermissions();
    _lastPermissionStatus = status;
    _log.success('requestPermissions → ${status.name}');
    notifyListeners();
  }

  Future<void> requestEnableBluetooth() async {
    final bool shown = await Printly.instance.requestEnableBluetooth();
    _log.success(
      'requestEnableBluetooth → '
      '${shown ? 'request shown' : 'no-op (already on / unavailable)'}',
    );
  }

  Future<void> openBluetoothSettings() async {
    final bool opened = await Printly.instance.openBluetoothSettings();
    _log.success('openBluetoothSettings → ${opened ? 'ok' : 'failed'}');
  }

  Future<void> openAppSettings() async {
    final bool opened = await Printly.instance.openAppSettings();
    _log.success('openAppSettings → ${opened ? 'ok' : 'failed'}');
  }

  @override
  void dispose() {
    unawaited(_adapterSub?.cancel());
    super.dispose();
  }
}

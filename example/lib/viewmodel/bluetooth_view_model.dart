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
    try {
      final PrintlyPermissionStatus status = await Printly.instance
          .requestPermissions();
      _lastPermissionStatus = status;
      _log.success('requestPermissions → ${status.name}');
      notifyListeners();
    } catch (error) {
      _log.failure('requestPermissions error → $error');
    }
  }

  Future<void> requestEnableBluetooth() async {
    try {
      final bool shown = await Printly.instance.requestEnableBluetooth();
      _log.success(
        'requestEnableBluetooth → '
        '${shown ? 'request shown' : 'no-op (already on / unavailable)'}',
      );
    } on PrintlyPermissionException catch (error) {
      // Android 12+ gates the enable dialog itself behind BLUETOOTH_CONNECT,
      // so printly refuses rather than firing an intent the OS would drop.
      // Surface the remedy instead of the raw error.
      _log.failure(
        'requestEnableBluetooth → grant Bluetooth permissions first '
        '(Request Bluetooth permissions above) · $error',
      );
    } catch (error) {
      _log.failure('requestEnableBluetooth error → $error');
    }
  }

  Future<void> openBluetoothSettings() async {
    try {
      final bool opened = await Printly.instance.openBluetoothSettings();
      _log.success('openBluetoothSettings → ${opened ? 'ok' : 'failed'}');
    } catch (error) {
      _log.failure('openBluetoothSettings error → $error');
    }
  }

  Future<void> openAppSettings() async {
    try {
      final bool opened = await Printly.instance.openAppSettings();
      _log.success('openAppSettings → ${opened ? 'ok' : 'failed'}');
    } catch (error) {
      _log.failure('openAppSettings error → $error');
    }
  }

  Future<void> openLocationSettings() async {
    try {
      final bool opened = await Printly.instance.openLocationSettings();
      _log.success(
        'openLocationSettings → '
        '${opened ? 'ok' : 'not applicable on this platform'}',
      );
    } catch (error) {
      // A MissingPluginException here means the running app still carries the
      // previous native build — a hot restart reloads Dart but not Kotlin.
      _log.failure('openLocationSettings error → $error');
    }
  }

  @override
  void dispose() {
    unawaited(_adapterSub?.cancel());
    super.dispose();
  }
}

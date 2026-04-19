import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/printly_device.dart';

/// Persistent store for the last-connected device and the auto-reconnect
/// preference.
///
/// Wraps [SharedPreferences] so the rest of the SDK does not have to know
/// about serialisation or key names. All reads/writes are async; values are
/// cached in-memory after the first load to keep repeated reads cheap.
class LastDeviceStore {
  /// Creates a store that persists to the given [SharedPreferences] instance.
  /// Tests can pass a mock instance obtained from
  /// `SharedPreferences.setMockInitialValues({...})`.
  LastDeviceStore(this._prefs);

  static const String _deviceKey = 'printly.last_connected_device';
  static const String _autoReconnectKey = 'printly.auto_reconnect_enabled';

  final SharedPreferences _prefs;

  /// Opens the default [SharedPreferences] instance and wraps it.
  static Future<LastDeviceStore> open() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return LastDeviceStore(prefs);
  }

  /// Returns the last-persisted device, or `null` if none has been saved or
  /// the stored payload is corrupt.
  PrintlyDevice? readDevice() {
    final String? raw = _prefs.getString(_deviceKey);
    if (raw == null) return null;
    try {
      final Object? decoded = json.decode(raw);
      if (decoded is! Map) return null;
      return PrintlyDevice.fromJson(decoded.cast<String, Object?>());
    } on FormatException {
      return null;
    }
  }

  /// Writes [device] to persistent storage. Passing `null` clears the
  /// previously persisted value.
  Future<void> writeDevice(PrintlyDevice? device) async {
    if (device == null) {
      await _prefs.remove(_deviceKey);
      return;
    }
    await _prefs.setString(_deviceKey, json.encode(device.toJson()));
  }

  /// Returns the persisted auto-reconnect flag. Defaults to `false`.
  bool readAutoReconnect() => _prefs.getBool(_autoReconnectKey) ?? false;

  /// Persists the auto-reconnect flag.
  Future<void> writeAutoReconnect({required bool enabled}) async {
    await _prefs.setBool(_autoReconnectKey, enabled);
  }
}

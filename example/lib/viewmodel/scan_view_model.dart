import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:printly/printly.dart';

import 'action_log_view_model.dart';

/// Discovery and connection lifecycle: the device list, the scan toggle and
/// connect/disconnect.
class ScanViewModel extends ChangeNotifier {
  ScanViewModel({required ActionLogViewModel log}) : _log = log;

  final ActionLogViewModel _log;

  List<PrintlyDevice> _devices = const <PrintlyDevice>[];
  bool _scanning = false;
  bool _namedOnly = true;
  PrintlyDevice? _activeDevice;

  StreamSubscription<List<PrintlyDevice>>? _devicesSub;
  StreamSubscription<bool>? _scanningSub;
  StreamSubscription<PrintlyDevice?>? _activeDeviceSub;

  bool get scanning => _scanning;
  bool get namedOnly => _namedOnly;
  PrintlyDevice? get activeDevice => _activeDevice;

  /// Every discovered device, unfiltered.
  List<PrintlyDevice> get devices => _devices;

  /// Scans surface many unnamed BLE beacons/peripherals; printers advertise a
  /// name, so hiding the unnamed noise keeps the list short and the UI smooth.
  List<PrintlyDevice> get visibleDevices => _namedOnly
      ? _devices
            .where((PrintlyDevice d) => (d.name ?? '').isNotEmpty)
            .toList(growable: false)
      : _devices;

  set namedOnly(bool value) {
    if (_namedOnly == value) return;
    _namedOnly = value;
    notifyListeners();
  }

  void start() {
    _devicesSub = Printly.instance.devicesStream.listen((
      List<PrintlyDevice> devices,
    ) {
      _devices = devices;
      notifyListeners();
    });
    _scanningSub = Printly.instance.isScanningStream.listen((bool scanning) {
      _scanning = scanning;
      notifyListeners();
    });
    _activeDeviceSub = Printly.instance.activeDeviceStream.listen((
      PrintlyDevice? device,
    ) {
      _activeDevice = device;
      notifyListeners();
    });
  }

  Future<void> toggleScan() async {
    try {
      if (_scanning) {
        await Printly.instance.stopScan();
        _log.success('stopScan → ok');
      } else {
        final PrintlyPermissionStatus current = await Printly.instance
            .checkPermissions();
        _log.success('checkPermissions → ${current.name}');
        if (current != PrintlyPermissionStatus.granted) {
          final PrintlyPermissionStatus asked = await Printly.instance
              .requestPermissions();
          _log.success('requestPermissions → ${asked.name}');
          if (asked != PrintlyPermissionStatus.granted) {
            _log.failure('scan aborted → permissions ${asked.name}');
            return;
          }
        }
        Printly.instance.clearDevices();
        await Printly.instance.startScan();
        _log.success('startScan → ok');
      }
    } catch (error) {
      _log.failure('scan error → $error');
    }
  }

  Future<void> connect(PrintlyDevice device) async {
    try {
      // Stop scanning first. Once the printer has been found the scan is pure
      // cost — battery, and on Android a radio busy scanning while a GATT link
      // is being set up is a well-known source of connection failures. printly
      // does not do this for you: silently cancelling a scan the app started
      // would be a surprising side effect, and an app juggling several
      // printers may genuinely want to keep looking.
      await stopScanIfRunning();
      _log.success(
        'connect attempt → ${device.address} '
        'transports=${device.availableTransports.map((ConnectionType t) => t.name).join('+')} '
        'seenInScan=${device.seenInScan} bonded=${device.isBonded}'
        '${device.rssi != null ? ' rssi=${device.rssi}' : ''}',
      );
      await Printly.instance.connect(device);
      _log.success(
        'connect → ${device.address} '
        'via ${Printly.instance.transportOf(device)?.name}',
      );
    } catch (error) {
      _log.failure(
        'connect error → '
        'via ${Printly.instance.transportOf(device)?.name ?? 'unresolved'} · $error',
      );
    }
  }

  /// Stops an in-flight scan; a no-op when nothing is running.
  ///
  /// Also called when the Scan tab goes off screen — a scan nobody is looking
  /// at is just radio time.
  Future<void> stopScanIfRunning() async {
    if (!_scanning) return;
    try {
      await Printly.instance.stopScan();
    } catch (error) {
      _log.failure('stopScan error → $error');
    }
  }

  Future<void> disconnect(PrintlyDevice device) async {
    try {
      await Printly.instance.disconnect(device: device);
      _log.success('disconnect → ${device.address}');
    } catch (error) {
      _log.failure('disconnect error → $error');
    }
  }

  @override
  void dispose() {
    unawaited(_devicesSub?.cancel());
    unawaited(_scanningSub?.cancel());
    unawaited(_activeDeviceSub?.cancel());
    super.dispose();
  }
}

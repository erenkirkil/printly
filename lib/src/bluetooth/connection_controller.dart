import 'dart:async';

import 'package:rxdart/rxdart.dart';

import '../core/connection_event.dart';
import '../core/connection_state.dart';
import '../core/printly_device.dart';
import '../platform/printly_platform_interface.dart';

/// Default timeout handed to [ConnectionController.connect] when the caller
/// does not provide one. Classic RFCOMM typically takes ~1–3 s; BLE GATT
/// can take longer on the first attempt while bonding completes.
const Duration kDefaultConnectTimeout = Duration(seconds: 10);

/// Owns the per-device connection lifecycle and exposes broadcast streams
/// for consumers.
///
/// The controller serialises native work so duplicate taps or rapid
/// connect/disconnect cycles never produce overlapping native calls:
///
/// * Concurrent [connect] calls for the same device share the same in-flight
///   future — no second native request is issued.
/// * [connect] for a new device while another is open first disconnects the
///   current one and then attempts the new one (queued, not parallel).
/// * [disconnect] while nothing is connected is a no-op.
///
/// Connection lifecycle events from the native side fan out into
/// [connectionStateOf] streams and a single [activeDeviceStream] observing
/// whichever device is currently connected.
class ConnectionController {
  /// Creates a controller that delegates native work to [platform].
  ConnectionController({PrintlyPlatform? platform})
    : _platform = platform ?? PrintlyPlatform.instance {
    _eventsSubscription = _platform.connectionEvents.listen(
      _onConnectionEvent,
      onError: _onConnectionEventError,
    );
  }

  final PrintlyPlatform _platform;

  final Map<String, BehaviorSubject<ConnectionState>> _states =
      <String, BehaviorSubject<ConnectionState>>{};
  final Map<String, PrintlyDevice> _knownDevices = <String, PrintlyDevice>{};
  final Map<String, String?> _lastFailureReasons = <String, String?>{};
  final Map<String, Future<void>> _pendingConnects = <String, Future<void>>{};
  final Map<String, Future<void>> _pendingDisconnects =
      <String, Future<void>>{};

  final BehaviorSubject<PrintlyDevice?> _activeDeviceSubject =
      BehaviorSubject<PrintlyDevice?>.seeded(null);

  StreamSubscription<PrintlyConnectionEvent>? _eventsSubscription;
  bool _disposed = false;

  /// Broadcast stream of the currently-connected device, or `null` when no
  /// link is open. Useful for wiring a "connected to: …" UI banner.
  Stream<PrintlyDevice?> get activeDeviceStream => _activeDeviceSubject.stream;

  /// Synchronous snapshot of [activeDeviceStream].
  PrintlyDevice? get activeDevice => _activeDeviceSubject.value;

  /// Per-device broadcast stream of state transitions. Always seeded with
  /// the last known state (defaults to [ConnectionState.disconnected] for
  /// devices the controller has not observed yet), so late subscribers
  /// immediately receive the current state.
  Stream<ConnectionState> connectionStateOf(PrintlyDevice device) =>
      _subjectFor(device).stream;

  /// Synchronous snapshot of [connectionStateOf] for [device].
  ConnectionState stateOf(PrintlyDevice device) =>
      _states[device.dedupKey]?.value ?? ConnectionState.disconnected;

  /// Most recent failure reason reported for [device], if any. Cleared on
  /// the next successful connect.
  String? lastFailureReasonOf(PrintlyDevice device) =>
      _lastFailureReasons[device.dedupKey];

  /// Opens a link to [device].
  ///
  /// * If already connected to [device] → returns immediately.
  /// * If a connect attempt is in flight for [device] → returns the same
  ///   future (re-entrancy safe).
  /// * If a different device is currently connected → disconnects it first,
  ///   then connects to [device] (serialised).
  Future<void> connect(
    PrintlyDevice device, {
    Duration timeout = kDefaultConnectTimeout,
  }) {
    _assertNotDisposed();
    final String key = device.dedupKey;

    final Future<void>? pending = _pendingConnects[key];
    if (pending != null) return pending;
    if (stateOf(device) == ConnectionState.connected) {
      return Future<void>.value();
    }

    final Future<void> future = _runConnect(device, timeout);
    _pendingConnects[key] = future;
    return future;
  }

  Future<void> _runConnect(PrintlyDevice device, Duration timeout) async {
    final String key = device.dedupKey;
    try {
      final PrintlyDevice? previous = activeDevice;
      if (previous != null && previous.dedupKey != key) {
        await _safeDisconnect(previous);
      }
      _knownDevices[key] = device;
      _lastFailureReasons[key] = null;
      _emitLocal(device, ConnectionState.connecting);
      await _platform.connect(device: device, timeout: timeout);
    } catch (error) {
      _lastFailureReasons[key] = error.toString();
      _emitLocal(device, ConnectionState.error);
      rethrow;
    } finally {
      unawaited(_pendingConnects.remove(key));
    }
  }

  /// Closes the current link. When [device] is omitted, disconnects the
  /// currently active device (if any).
  ///
  /// * No-op when the target is already disconnected.
  /// * Re-entrancy safe: concurrent calls share a single pending future.
  Future<void> disconnect({PrintlyDevice? device}) {
    _assertNotDisposed();
    final PrintlyDevice? target = device ?? activeDevice;
    if (target == null) return Future<void>.value();

    final String key = target.dedupKey;
    final Future<void>? pending = _pendingDisconnects[key];
    if (pending != null) return pending;

    final ConnectionState current = stateOf(target);
    if (current == ConnectionState.disconnected) {
      return Future<void>.value();
    }

    final Future<void> future = _runDisconnect(target);
    _pendingDisconnects[key] = future;
    return future;
  }

  Future<void> _runDisconnect(PrintlyDevice device) async {
    final String key = device.dedupKey;
    try {
      _emitLocal(device, ConnectionState.disconnecting);
      await _platform.disconnect(device: device);
    } finally {
      unawaited(_pendingDisconnects.remove(key));
    }
  }

  /// Disconnects without throwing — used when [connect] needs to switch away
  /// from a previous device. A failure to gracefully close is acceptable
  /// because the new connect attempt is about to replace the link anyway.
  Future<void> _safeDisconnect(PrintlyDevice device) async {
    try {
      await disconnect(device: device);
    } catch (_) {
      /* best-effort */
    }
  }

  void _onConnectionEvent(PrintlyConnectionEvent event) {
    if (_disposed) return;
    _knownDevices[event.device.dedupKey] = event.device;
    if (event.state == ConnectionState.error) {
      _lastFailureReasons[event.device.dedupKey] = event.failureReason;
    } else if (event.state == ConnectionState.connected) {
      _lastFailureReasons[event.device.dedupKey] = null;
    }
    _emitLocal(event.device, event.state);
  }

  void _onConnectionEventError(Object error, StackTrace stack) {
    /* Swallow — native will emit an error event when the state actually
       changes. No global invalidation needed. */
  }

  void _emitLocal(PrintlyDevice device, ConnectionState state) {
    _subjectFor(device).add(state);
    _updateActiveDevice(device, state);
  }

  void _updateActiveDevice(PrintlyDevice device, ConnectionState state) {
    final PrintlyDevice? current = _activeDeviceSubject.value;
    if (state == ConnectionState.connected) {
      if (current?.dedupKey != device.dedupKey) {
        _activeDeviceSubject.add(device);
      }
      return;
    }
    if (current?.dedupKey == device.dedupKey &&
        state != ConnectionState.connecting &&
        state != ConnectionState.reconnecting) {
      _activeDeviceSubject.add(null);
    }
  }

  BehaviorSubject<ConnectionState> _subjectFor(PrintlyDevice device) {
    return _states.putIfAbsent(
      device.dedupKey,
      () =>
          BehaviorSubject<ConnectionState>.seeded(ConnectionState.disconnected),
    );
  }

  void _assertNotDisposed() {
    if (_disposed) {
      throw StateError('ConnectionController used after dispose()');
    }
  }

  /// Releases subscriptions and subjects. Called from tests; the production
  /// singleton lives for the process lifetime.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _eventsSubscription?.cancel();
    _eventsSubscription = null;
    await _activeDeviceSubject.close();
    for (final BehaviorSubject<ConnectionState> subject in _states.values) {
      await subject.close();
    }
    _states.clear();
    _pendingConnects.clear();
    _pendingDisconnects.clear();
  }
}

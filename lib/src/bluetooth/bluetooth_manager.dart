import 'dart:async';

import '../platform/printly_platform_interface.dart';
import 'bluetooth_adapter_state.dart';

/// Internal manager that wraps the platform [PrintlyPlatform.adapterState]
/// stream and caches the latest emitted value so that synchronous getters
/// such as `Printly.instance.isBluetoothAvailable` can be served without a
/// round-trip to the platform channel.
///
/// The cache is only populated while at least one subscriber is attached to
/// [stream]; before that the cached state stays at
/// [BluetoothAdapterState.unknown].
class BluetoothManager {
  /// Creates a manager bound to the given [platform] instance. Defaults to
  /// the registered [PrintlyPlatform.instance] when omitted.
  BluetoothManager({PrintlyPlatform? platform})
    : _platform = platform ?? PrintlyPlatform.instance;

  final PrintlyPlatform _platform;

  final StreamController<BluetoothAdapterState> _controller =
      StreamController<BluetoothAdapterState>.broadcast();

  StreamSubscription<BluetoothAdapterState>? _subscription;

  BluetoothAdapterState _currentState = BluetoothAdapterState.unknown;

  /// Most recently observed adapter state.
  ///
  /// Defaults to [BluetoothAdapterState.unknown] until the first event is
  /// received from the platform.
  BluetoothAdapterState get currentState => _currentState;

  /// Broadcast stream of adapter state changes.
  ///
  /// The underlying native observer is started on first subscription and
  /// stays alive for the lifetime of the application. This matches the
  /// typical usage pattern where the SDK is consumed as a singleton.
  Stream<BluetoothAdapterState> get stream {
    _ensureStarted();
    return _controller.stream;
  }

  /// Convenience flag mirroring
  /// `currentState == BluetoothAdapterState.poweredOn`. Returns `false`
  /// before the first state event arrives.
  bool get isBluetoothAvailable =>
      _currentState == BluetoothAdapterState.poweredOn;

  void _ensureStarted() {
    if (_subscription != null) {
      return;
    }
    _subscription = _platform.adapterState.listen((
      BluetoothAdapterState state,
    ) {
      _currentState = state;
      _controller.add(state);
    }, onError: _controller.addError);
  }

  /// Cancels the native subscription. Intended for tests; the SDK does not
  /// dispose managers at runtime.
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _controller.close();
  }
}

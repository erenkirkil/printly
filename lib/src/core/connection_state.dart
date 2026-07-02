/// Lifecycle of a single device connection.
///
/// State transitions are always observed through [Printly.instance]
/// connection streams; they are never mutated by the caller.
///
/// Typical happy-path sequence:
///
/// ```
/// disconnected → connecting → connected → disconnecting → disconnected
/// ```
///
/// A failed attempt ends in [error]; the accompanying failure reason is
/// delivered via the connection failure API rather than embedded in the
/// enum so that the enum itself stays comparable by value.
enum ConnectionState {
  /// No link is open and no attempt is in progress.
  disconnected,

  /// A link is being established. Re-entrant `connect()` calls observing this
  /// state return the in-flight future instead of starting a new attempt.
  connecting,

  /// The link is open and usable for print jobs.
  connected,

  /// A graceful close is in progress.
  disconnecting,

  /// Reserved for a future native auto-reconnect flow. **Not emitted in the
  /// current release** — the Dart-side auto-reconnect retries via a plain
  /// connect, which reports [connecting]. The wire code stays allocated so
  /// enabling it later is not a breaking change.
  reconnecting,

  /// The last connection attempt ended in a failure. The connection controller
  /// exposes the accompanying reason.
  error;

  /// Stable wire code shared with the native side. Do not reorder.
  int get wireCode => switch (this) {
    ConnectionState.disconnected => 0,
    ConnectionState.connecting => 1,
    ConnectionState.connected => 2,
    ConnectionState.disconnecting => 3,
    ConnectionState.reconnecting => 4,
    ConnectionState.error => 5,
  };

  /// Decodes a [wireCode] received from the native side. Unknown values fall
  /// back to [ConnectionState.disconnected] so a malformed event does not
  /// crash the stream.
  static ConnectionState fromWireCode(int code) => switch (code) {
    0 => ConnectionState.disconnected,
    1 => ConnectionState.connecting,
    2 => ConnectionState.connected,
    3 => ConnectionState.disconnecting,
    4 => ConnectionState.reconnecting,
    5 => ConnectionState.error,
    _ => ConnectionState.disconnected,
  };

  /// True while a link is open ([ConnectionState.connected]) — safe to send
  /// print jobs.
  bool get isConnected => this == ConnectionState.connected;

  /// True while the controller is actively trying to open or restore a link.
  bool get isInProgress =>
      this == ConnectionState.connecting ||
      this == ConnectionState.reconnecting;
}

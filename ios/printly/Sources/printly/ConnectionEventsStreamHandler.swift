import Flutter

/// Pure event sink for `printly/connection_events`. The coordinator feeds
/// it by calling [emit]; since we run on the main queue throughout (see
/// CentralController), no cross-thread hop is needed.
final class ConnectionEventsStreamHandler: NSObject, FlutterStreamHandler {

    private var sink: FlutterEventSink?

    func onListen(
        withArguments _: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        sink = events
        return nil
    }

    func onCancel(withArguments _: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    func emit(_ event: [String: Any]) {
        sink?(event)
    }

    func detach() {
        sink = nil
    }
}

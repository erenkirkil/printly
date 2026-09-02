import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';
import 'package:printly/src/network/tcp_printer_transport.dart';

PrintlyDevice deviceFor(int port) =>
    PrintlyDevice.network(host: '127.0.0.1', port: port, name: 'loopback');

void main() {
  test('connect to a live loopback server emits connected', () async {
    final ServerSocket server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final TcpPrinterTransport transport = TcpPrinterTransport();
    final PrintlyDevice device = deviceFor(server.port);

    final Future<PrintlyConnectionEvent> firstEvent = transport.events.first;
    await transport.connect(device);
    final PrintlyConnectionEvent event = await firstEvent;

    expect(event.state, ConnectionState.connected);
    expect(event.device.dedupKey, device.dedupKey);

    await transport.dispose();
    await server.close();
  });

  test('connect to a closed port reports connect_failed on the event stream '
      'and does not also reject', () async {
    // One report per outcome, matching the native coordinators: the event
    // is it. A rejection on top would resolve the caller's attempt first and
    // leave the event to land on whatever attempt comes next — see the
    // retry-from-the-catch-block regression in
    // test/platform/network_routing_platform_test.dart.
    //
    // Bind then immediately close to get a port nothing listens on.
    final ServerSocket probe = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final int deadPort = probe.port;
    await probe.close();

    final TcpPrinterTransport transport = TcpPrinterTransport();
    final PrintlyDevice device = deviceFor(deadPort);
    final Future<PrintlyConnectionEvent> errEvent = transport.events.first;

    await expectLater(transport.connect(device), completes);
    final PrintlyConnectionEvent event = await errEvent;
    expect(event.state, ConnectionState.error);
    expect(event.failureReason, contains('connect_failed'));
    expect(event.device.dedupKey, device.dedupKey);

    await transport.dispose();
  });

  test(
    'an unparseable address reports connect_failed on the event stream',
    () async {
      // Reachable from a hand-built device (the network factory always produces
      // host:port), and it must land on the same channel as every other connect
      // failure rather than throwing past the controller's event path.
      final TcpPrinterTransport transport = TcpPrinterTransport();
      final PrintlyDevice device = PrintlyDevice(
        address: 'printer.local',
        availableTransports: <ConnectionType>{ConnectionType.network},
        name: 'no port',
      );
      final Future<PrintlyConnectionEvent> errEvent = transport.events.first;

      await expectLater(transport.connect(device), completes);
      final PrintlyConnectionEvent event = await errEvent;
      expect(event.state, ConnectionState.error);
      expect(event.failureReason, contains('connect_failed'));
      expect(event.failureReason, contains('printer.local'));

      await transport.dispose();
    },
  );

  test('connect timeout reports connect_timeout on the event stream when the '
      'connector never completes', () async {
    final Completer<Socket> never = Completer<Socket>();
    final TcpPrinterTransport transport = TcpPrinterTransport(
      connector: (String host, int port, {Duration? timeout}) => never.future,
    );
    final PrintlyDevice device = deviceFor(9100);
    final Future<PrintlyConnectionEvent> errEvent = transport.events.first;

    await expectLater(
      transport.connect(device, timeout: const Duration(milliseconds: 300)),
      completes,
    );
    final PrintlyConnectionEvent event = await errEvent;
    expect(event.state, ConnectionState.error);
    // The bare wire reason, so the controller maps it to `connectTimeout`
    // rather than the generic `connectFailed` fallback.
    expect(event.failureReason, PrintlyErrorCode.connectTimeout.wireName);

    await transport.dispose();
  });

  test('a second connect to an already-open session re-emits connected '
      'without opening a new socket', () async {
    final ServerSocket server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    int accepted = 0;
    server.listen((Socket s) => accepted++);
    final TcpPrinterTransport transport = TcpPrinterTransport();
    final PrintlyDevice device = deviceFor(server.port);

    await transport.connect(device);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await transport.connect(device);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(accepted, 1);

    await transport.dispose();
    await server.close();
  });

  test('disconnect destroys the socket and emits disconnected', () async {
    final ServerSocket server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final TcpPrinterTransport transport = TcpPrinterTransport();
    final PrintlyDevice device = deviceFor(server.port);

    await transport.connect(device);
    final Future<PrintlyConnectionEvent> disc = transport.events.firstWhere(
      (PrintlyConnectionEvent e) => e.state == ConnectionState.disconnected,
    );
    await transport.disconnect(device);
    final PrintlyConnectionEvent event = await disc;
    expect(event.state, ConnectionState.disconnected);

    await transport.dispose();
    await server.close();
  });

  test('disconnect with no open session does not throw', () async {
    final TcpPrinterTransport transport = TcpPrinterTransport();
    await transport.disconnect(deviceFor(9100)); // must not throw
    await transport.dispose();
  });

  test('remote close emits disconnected exactly once', () async {
    final ServerSocket server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final TcpPrinterTransport transport = TcpPrinterTransport();
    final PrintlyDevice device = deviceFor(server.port);

    Socket? accepted;
    server.listen((Socket s) => accepted = s);
    await transport.connect(device);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    int disconnects = 0;
    transport.events
        .where(
          (PrintlyConnectionEvent e) => e.state == ConnectionState.disconnected,
        )
        .listen((_) => disconnects++);

    await accepted!.close();
    accepted!.destroy();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(disconnects, 1);

    await transport.dispose();
    await server.close();
  });

  test(
    'remote close destroys the client socket instead of leaking it',
    () async {
      // A leaked descriptor is invisible to an event-count assertion, so this
      // watches the peer instead: only a destroyed client socket sends the FIN
      // that ends the server's read stream. A socket merely dropped from the
      // session map sits in CLOSE_WAIT for the life of the process, and a POS
      // app reconnecting per receipt would burn one descriptor per receipt.
      final ServerSocket server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final Completer<void> peerSawEof = Completer<void>();
      server.listen((Socket peer) {
        peer.listen(
          (_) {},
          onDone: () {
            if (!peerSawEof.isCompleted) peerSawEof.complete();
          },
        );
        // Half-close: FIN to the client, which is what an idle-timing printer or
        // an intervening print server does.
        unawaited(peer.close());
      });

      final TcpPrinterTransport transport = TcpPrinterTransport();
      final PrintlyDevice device = deviceFor(server.port);
      final Future<PrintlyConnectionEvent> disc = transport.events.firstWhere(
        (PrintlyConnectionEvent e) => e.state == ConnectionState.disconnected,
      );

      await transport.connect(device);
      await disc;
      await expectLater(
        peerSawEof.future.timeout(const Duration(seconds: 5)),
        completes,
      );

      await transport.dispose();
      await server.close();
    },
  );

  test('disconnect during an in-flight dial cancels it', () async {
    final ServerSocket server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final Completer<void> peerSawEof = Completer<void>();
    server.listen((Socket peer) {
      peer.listen(
        (_) {},
        onDone: () {
          if (!peerSawEof.isCompleted) peerSawEof.complete();
        },
      );
    });

    // Gate the dial so the disconnect lands while the socket is still opening
    // — the window in which the session map is still empty.
    final Completer<void> gate = Completer<void>();
    final TcpPrinterTransport transport = TcpPrinterTransport(
      connector: (String host, int port, {Duration? timeout}) async {
        await gate.future;
        return Socket.connect(host, port);
      },
    );
    final PrintlyDevice device = deviceFor(server.port);
    final List<ConnectionState> states = <ConnectionState>[];
    transport.events.listen((PrintlyConnectionEvent e) => states.add(e.state));

    final Future<void> dial = transport.connect(device);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await transport.disconnect(device);
    gate.complete();
    await dial;
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // A cancelled attempt must not report success after the caller stopped it
    // (the controller above would resolve the pending connect as connected),
    // and the socket that arrives late must not be kept open.
    expect(states, <ConnectionState>[ConnectionState.disconnected]);
    await expectLater(
      peerSawEof.future.timeout(const Duration(seconds: 5)),
      completes,
    );

    await transport.dispose();
    await server.close();
  });

  test('disconnect with neither a session nor a dial still emits '
      'disconnected exactly once', () async {
    // The native contract, not an accident: ConnectionCoordinator.kt and
    // ConnectionCoordinator.swift both emit `disconnected` for a session they
    // do not have. ConnectionController emits `disconnecting` locally and then
    // waits for the transport's terminal event, so a silent no-op wedges the
    // device in `disconnecting` — see the controller-level regression in
    // test/platform/network_routing_platform_test.dart. Exactly once, so a
    // teardown cannot fan out into repeated terminal states.
    final TcpPrinterTransport transport = TcpPrinterTransport();
    final List<PrintlyConnectionEvent> events = <PrintlyConnectionEvent>[];
    transport.events.listen(events.add);

    await transport.disconnect(deviceFor(9100));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(events, hasLength(1));
    expect(events.single.state, ConnectionState.disconnected);

    await transport.dispose();
  });

  test(
    'write sends bytes the server receives, and completes after flush',
    () async {
      final ServerSocket server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final List<int> received = <int>[];
      final Completer<void> gotBytes = Completer<void>();
      server.listen((Socket s) {
        s.listen((List<int> data) {
          received.addAll(data);
          if (!gotBytes.isCompleted) gotBytes.complete();
        });
      });
      final TcpPrinterTransport transport = TcpPrinterTransport();
      final PrintlyDevice device = deviceFor(server.port);

      await transport.connect(device);
      await transport.write(
        device,
        Uint8List.fromList(<int>[0x1B, 0x40, 0x41]),
      );
      await gotBytes.future;

      expect(received, <int>[0x1B, 0x40, 0x41]);

      await transport.dispose();
      await server.close();
    },
  );

  test('write with no open session throws notConnected', () async {
    final TcpPrinterTransport transport = TcpPrinterTransport();
    await expectLater(
      transport.write(deviceFor(9100), Uint8List.fromList(<int>[0x41])),
      throwsA(
        isA<PrintlyWriteException>().having(
          (PrintlyWriteException e) => e.code,
          'code',
          PrintlyErrorCode.notConnected,
        ),
      ),
    );
    await transport.dispose();
  });

  test(
    'a second write while the first is in flight throws writeBusy',
    () async {
      final ServerSocket server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      // Server never reads, so the first flush stays pending and the overlap is
      // real rather than a scheduling accident.
      server.listen((Socket s) {
        /* do not read */
      });
      final TcpPrinterTransport transport = TcpPrinterTransport();
      final PrintlyDevice device = deviceFor(server.port);
      await transport.connect(device);

      // 8 MiB, not 1 MiB: loopback send/receive buffers autotune into the
      // megabytes, so a 1 MiB payload flushes in about a millisecond even with
      // nobody reading. Measured on this platform. The short writeTimeout keeps
      // the unflushable write from pinning the test for the 30 s default.
      final Future<void> first = transport.write(
        device,
        Uint8List(1 << 23),
        writeTimeout: const Duration(milliseconds: 300),
      );
      await expectLater(
        transport.write(device, Uint8List.fromList(<int>[0x41])),
        throwsA(
          isA<PrintlyWriteException>().having(
            (PrintlyWriteException e) => e.code,
            'code',
            PrintlyErrorCode.writeBusy,
          ),
        ),
      );

      // Let the first settle so dispose is clean; it times out and tears the
      // session down.
      await first.catchError((_) {});
      await transport.dispose();
      await server.close();
    },
  );

  test('write timeout closes the session and emits disconnected', () async {
    final ServerSocket server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((Socket s) {
      /* never read -> flush hangs */
    });
    final TcpPrinterTransport transport = TcpPrinterTransport();
    final PrintlyDevice device = deviceFor(server.port);
    await transport.connect(device);

    final Future<PrintlyConnectionEvent> disc = transport.events.firstWhere(
      (PrintlyConnectionEvent e) => e.state == ConnectionState.disconnected,
    );

    await expectLater(
      transport.write(
        device,
        Uint8List(1 << 23),
        writeTimeout: const Duration(milliseconds: 300),
      ),
      throwsA(
        isA<PrintlyWriteException>().having(
          (PrintlyWriteException e) => e.code,
          'code',
          PrintlyErrorCode.writeTimeout,
        ),
      ),
    );
    final PrintlyConnectionEvent event = await disc;
    expect(event.state, ConnectionState.disconnected);

    await transport.dispose();
    await server.close();
  });

  test(
    'a peer that hangs up mid-write fails the write as disconnected',
    () async {
      // The common real-world hangup is graceful, not abortive: a print server
      // that idle-closes, a printer that drops the link on paper-out, a spooler
      // cycling. It sends FIN, and dart:io completes the pending flush future
      // *normally* once the socket is destroyed under it — so "flush returned"
      // is not on its own evidence that the job was sent. Without a post-flush
      // liveness check this write reports success for a receipt the printer
      // never received, while the transport has already emitted `disconnected`
      // for the very same device.
      final ServerSocket server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      Socket? peer;
      server.listen((Socket s) => peer = s); // accepted, never read

      final TcpPrinterTransport transport = TcpPrinterTransport();
      final PrintlyDevice device = deviceFor(server.port);
      await transport.connect(device);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Generous deadline on purpose: this test is about the `disconnected`
      // classification, so the writeTimeout branch must not be what fires.
      bool settled = false;
      final Future<void> write = transport.write(
        device,
        Uint8List(1 << 23),
        writeTimeout: const Duration(seconds: 30),
      );
      unawaited(
        write.then<void>(
          (_) => settled = true,
          onError: (Object _) => settled = true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Fence for the fixture, not the code: if this payload ever flushes with
      // nobody reading, the mid-write window is gone and the assertion below
      // would pass for the wrong reason.
      expect(
        settled,
        isFalse,
        reason: '8 MiB must still be unflushed while the peer never reads',
      );

      await peer!.close(); // graceful FIN

      await expectLater(
        write,
        throwsA(
          isA<PrintlyWriteException>().having(
            (PrintlyWriteException e) => e.code,
            'code',
            PrintlyErrorCode.disconnected,
          ),
        ),
      );

      await transport.dispose();
      await server.close();
    },
  );

  test('disconnect during a write fails that write as disconnected', () async {
    // Same hole reached through the local door: `disconnect` destroys the
    // socket out from under an in-flight flush. The caller that asked to
    // disconnect knows why, but the caller awaiting `write` must not be told
    // its half-sent job succeeded.
    final ServerSocket server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((Socket s) {
      /* accepted, never read */
    });

    final TcpPrinterTransport transport = TcpPrinterTransport();
    final PrintlyDevice device = deviceFor(server.port);
    await transport.connect(device);

    bool settled = false;
    final Future<void> write = transport.write(
      device,
      Uint8List(1 << 23),
      writeTimeout: const Duration(seconds: 30),
    );
    unawaited(
      write.then<void>(
        (_) => settled = true,
        onError: (Object _) => settled = true,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      settled,
      isFalse,
      reason: '8 MiB must still be unflushed while the peer never reads',
    );

    await transport.disconnect(device);

    await expectLater(
      write,
      throwsA(
        isA<PrintlyWriteException>().having(
          (PrintlyWriteException e) => e.code,
          'code',
          PrintlyErrorCode.disconnected,
        ),
      ),
    );

    await transport.dispose();
    await server.close();
  });
}

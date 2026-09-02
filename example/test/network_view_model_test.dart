import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';
import 'package:printly_example/viewmodel/action_log_view_model.dart';
import 'package:printly_example/viewmodel/network_view_model.dart';
import 'package:printly_example/viewmodel/settings_view_model.dart';

void main() {
  late ActionLogViewModel log;
  late SettingsViewModel settings;
  late NetworkViewModel vm;

  setUp(() {
    log = ActionLogViewModel();
    settings = SettingsViewModel();
    // NOTE: start() is deliberately NOT called — it subscribes to a live
    // platform stream. Everything asserted here is pure state.
    vm = NetworkViewModel(log: log, settings: settings);
  });

  tearDown(() {
    vm.dispose();
    settings.dispose();
    log.dispose();
  });

  test('defaults to port 9100 and an empty host', () {
    expect(vm.port, 9100);
    expect(vm.host, isEmpty);
    expect(vm.device, isNull);
    expect(vm.canConnect, isFalse);
  });

  test('setting a host builds a network device with host:port address', () {
    vm.host = '192.168.0.5';
    expect(vm.device, isNotNull);
    expect(vm.device!.address, '192.168.0.5:9100');
    expect(vm.device!.availableTransports, <ConnectionType>{
      ConnectionType.network,
    });
    expect(vm.canConnect, isTrue);
  });

  test('a custom port is reflected in the address', () {
    vm.host = '10.0.0.9';
    vm.port = 9101;
    expect(vm.device!.address, '10.0.0.9:9101');
  });

  test('host is trimmed', () {
    vm.host = '  192.168.0.5  ';
    expect(vm.device!.address, '192.168.0.5:9100');
  });

  test('useRecent restores host and port from a host:port string', () {
    vm.useRecent('192.168.1.20:9102');
    expect(vm.host, '192.168.1.20');
    expect(vm.port, 9102);
  });

  test('setting the same host twice does not notify twice', () {
    int notifications = 0;
    vm.addListener(() => notifications++);
    vm.host = '192.168.0.5';
    vm.host = '192.168.0.5';
    expect(notifications, 1);
  });

  test('canPrint is false while disconnected', () {
    vm.host = '192.168.0.5';
    expect(vm.state, ConnectionState.disconnected);
    expect(vm.canPrint, isFalse);
  });
}

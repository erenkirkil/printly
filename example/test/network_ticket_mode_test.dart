import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';
import 'package:printly_example/model/receipt_templates.dart';
import 'package:printly_example/viewmodel/action_log_view_model.dart';
import 'package:printly_example/viewmodel/network_view_model.dart';
import 'package:printly_example/viewmodel/settings_view_model.dart';

/// Ticket mode wraps every job in Custom's alignment commands and ends it
/// with `GS F8` (align to cutter) + `ESC i` (total cut). Anything the encoder
/// appends *after* that cut moves paper past the notch the cut just landed on,
/// and the next job's `GS F6` then skips the half-fed ticket — which comes out
/// blank. This is the regression behind "one extra blank ticket per print".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const List<int> alignToCutter = <int>[0x1D, 0xF8];
  const List<int> totalCut = <int>[0x1B, 0x69];

  test('ticketJobConfig drops the trailing feed and the GS V cut', () {
    final PrintConfig source = PrintConfig(
      paperWidth: PrintlyPaperWidth.mm58,
      feedLines: 3,
      cutAfterPrint: true,
    );
    final PrintConfig ticket = NetworkViewModel.ticketJobConfig(source);
    expect(ticket.feedLines, 0);
    expect(ticket.cutAfterPrint, isFalse);
    // Everything else is untouched.
    expect(ticket.paperWidth, source.paperWidth);
    expect(ticket.charset, source.charset);
  });

  test(
    'a ticket-mode job ends exactly on the cut — nothing after ESC i',
    () async {
      final ReceiptTemplate template = ReceiptTemplates.layout(
        PrintlyPaperWidth.mm58,
      );
      final PrintJob job = await Printly.instance.newJob(
        config: NetworkViewModel.ticketJobConfig(template.config),
      );
      template.build(job);
      job
        ..raw(alignToCutter)
        ..raw(totalCut);

      final Uint8List bytes = job.build();
      final List<int> tail = bytes.sublist(bytes.length - 4);
      expect(
        tail,
        <int>[...alignToCutter, ...totalCut],
        reason:
            'bytes after the cut feed paper past the notch and produce a '
            'blank ticket on the next job',
      );
    },
  );

  group('align-to-print-head is emitted once per connection', () {
    late NetworkViewModel vm;

    setUp(() {
      vm = NetworkViewModel(
        log: ActionLogViewModel(),
        settings: SettingsViewModel(),
      )..ticketMode = true;
    });

    tearDown(() => vm.dispose());

    test('a fresh connection needs the alignment command', () {
      expect(vm.needsTicketAlignment, isTrue);
    });

    test('once aligned, later jobs must not send it again', () {
      vm.markTicketAligned();
      expect(
        vm.needsTicketAlignment,
        isFalse,
        reason:
            'ESC i already retracts the paper to the next ticket top; a '
            'second GS F6 skips a whole ticket',
      );
    });

    test(
      'reconnecting re-arms it, because the paper may have been reloaded',
      () {
        vm.markTicketAligned();
        vm.resetTicketAlignment();
        expect(vm.needsTicketAlignment, isTrue);
      },
    );

    test('roll paper never asks for it', () {
      vm.ticketMode = false;
      expect(vm.needsTicketAlignment, isFalse);
    });
  });
}

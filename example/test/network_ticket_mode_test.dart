import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:printly/printly.dart';
import 'package:printly_example/model/receipt_templates.dart';
import 'package:printly_example/viewmodel/action_log_view_model.dart';
import 'package:printly_example/viewmodel/network_view_model.dart';
import 'package:printly_example/viewmodel/settings_view_model.dart';

/// Ticket mode ends every job with `GS F8` (align to cutter) + `ESC i` (total
/// cut), which retracts the paper to the next ticket's top edge. Anything the
/// encoder appends *after* that cut moves the paper off that edge, and an
/// align-to-print-head (`GS F6`) on already-aligned paper skips a whole
/// ticket — both come out as "one extra blank ticket per print".
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

  // The TK180 aligns the paper to the notch by itself when stock is loaded,
  // and `ESC i` retracts it to the next ticket's top edge after every cut.
  // `GS F6` on already-aligned paper advances a whole ticket, so a job that
  // opens with it prints one full ticket plus a blank one — seen on paper on
  // the first job after connecting, with freshly loaded stock.
  group('align-to-print-head is never added to a job', () {
    late NetworkViewModel vm;

    setUp(() {
      vm = NetworkViewModel(
        log: ActionLogViewModel(),
        settings: SettingsViewModel(),
      )..ticketMode = true;
    });

    tearDown(() => vm.dispose());

    test('the first ticket-mode job does not open with GS F6', () async {
      final PrintJob job = await vm.newJob(
        PrintConfig(paperWidth: PrintlyPaperWidth.mm58),
      );
      expect(
        _containsSequence(job.build(), alignToPrintHead),
        isFalse,
        reason:
            'the printer has already aligned the paper; GS F6 skips a '
            'whole ticket, which comes out blank',
      );
    });

    test(
      'the manual align job is GS F6 alone — no cut or feed after it',
      () async {
        final PrintJob job = await vm.alignTicketJob();
        final Uint8List bytes = job.build();
        expect(bytes.sublist(bytes.length - 2), alignToPrintHead);
        expect(
          _containsSequence(bytes, totalCut),
          isFalse,
          reason: 'aligning must not cut; the paper is not printed yet',
        );
      },
    );
  });
}

const List<int> alignToPrintHead = <int>[0x1D, 0xF6];

bool _containsSequence(List<int> bytes, List<int> sequence) {
  for (int i = 0; i + sequence.length <= bytes.length; i++) {
    int matched = 0;
    while (matched < sequence.length &&
        bytes[i + matched] == sequence[matched]) {
      matched++;
    }
    if (matched == sequence.length) return true;
  }
  return false;
}

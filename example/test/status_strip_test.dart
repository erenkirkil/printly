import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:printly_example/model/action_log.dart';
import 'package:printly_example/view/widgets/status_strip.dart';

void main() {
  testWidgets('tapping the strip opens the history sheet with known entries', (
    WidgetTester tester,
  ) async {
    final DateTime now = DateTime(2026, 1, 1, 12, 30, 45);
    final List<ActionLog> history = <ActionLog>[
      ActionLog(
        message: 'connect error → PrintlyConnectionException(connect_timeout)',
        isError: true,
        at: now,
      ),
      ActionLog(
        message: 'connect attempt → 00:11:22:33:44:55',
        isError: false,
        at: now,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatusStrip(
            log: history.first,
            history: history,
            onClear: () {},
          ),
        ),
      ),
    );

    expect(
      find.textContaining('PrintlyConnectionException(connect_timeout)'),
      findsOneWidget,
    );

    await tester.tap(find.byType(InkWell));
    await tester.pumpAndSettle();

    expect(find.text('Action log'), findsOneWidget);
    expect(
      find.textContaining('connect attempt → 00:11:22:33:44:55'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'connect error → PrintlyConnectionException(connect_timeout)',
      ),
      findsWidgets,
    );
  });
}

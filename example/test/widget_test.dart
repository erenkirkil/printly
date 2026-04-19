import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:printly_example/main.dart';

void main() {
  testWidgets('PrintlyExampleApp renders without errors', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const PrintlyExampleApp());
    await tester.pump();

    expect(find.byType(MaterialApp), findsOneWidget);
  });
}

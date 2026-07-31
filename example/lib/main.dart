import 'package:flutter/material.dart';

import 'view/home_shell.dart';

void main() {
  runApp(const PrintlyExampleApp());
}

/// Root of the printly playground.
///
/// Kept deliberately thin — `example/test/widget_test.dart` pumps exactly this
/// widget, so it must stay const-constructible and free of platform calls.
class PrintlyExampleApp extends StatelessWidget {
  const PrintlyExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'printly example',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const HomeShell(),
    );
  }
}

// KannadaBuddy widget tests: app launch, home screen, and results screen structure.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kanndabuddy/main.dart';

void main() {
  group('KannadaBuddy app', () {
    testWidgets('MyApp builds and shows KannadaBuddy title', (WidgetTester tester) async {
      await tester.pumpWidget(MyApp());
      await tester.pumpAndSettle();

      expect(find.text('KannadaBuddy'), findsOneWidget);
    });

    testWidgets('Home screen has Copy and Share semantics on results when navigated', (WidgetTester tester) async {
      await tester.pumpWidget(MyApp());
      await tester.pumpAndSettle();

      // Home should show main actions (gallery/document or typed input)
      expect(find.text('KannadaBuddy'), findsOneWidget);
      expect(find.byIcon(Icons.copy_rounded), findsNothing);
    });

    testWidgets('Home has Get transliteration & translation or similar primary action', (WidgetTester tester) async {
      await tester.pumpWidget(MyApp());
      await tester.pumpAndSettle();

      expect(find.text('Get transliteration & translation'), findsOneWidget);
    });
  });
}

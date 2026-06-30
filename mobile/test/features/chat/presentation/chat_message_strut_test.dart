import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/main.dart';

void main() {
  testWidgets('one-line Chinese and Korean messages use the same height', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());

    await tester.pumpAndSettle();

    final Finder bubbleFinder = find.byKey(
      const ValueKey<String>('incoming-bubble-1'),
    );

    final Finder originalTextFinder = find.text('欧巴我快要登机了');

    expect(bubbleFinder, findsOneWidget);
    expect(originalTextFinder, findsOneWidget);

    final double originalBubbleHeight = tester.getSize(bubbleFinder).height;

    final double originalTextHeight = tester.getSize(originalTextFinder).height;

    await tester.tap(originalTextFinder);
    await tester.pump();

    expect(find.text('Translating…'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));

    await tester.pumpAndSettle();

    final Finder translatedTextFinder = find.text('오빠, 나 곧 탑승해.');

    expect(translatedTextFinder, findsOneWidget);

    final double translatedBubbleHeight = tester.getSize(bubbleFinder).height;

    final double translatedTextHeight = tester
        .getSize(translatedTextFinder)
        .height;

    expect(translatedTextHeight, closeTo(originalTextHeight, 0.01));

    expect(translatedBubbleHeight, closeTo(originalBubbleHeight, 0.01));
  });
}

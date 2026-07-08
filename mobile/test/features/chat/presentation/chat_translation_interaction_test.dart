import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/juliatalk_preview_app.dart';

Future<void> _scrollConversationToStart(WidgetTester tester) async {
  final Finder messageListFinder = find.byKey(
    const ValueKey<String>('message-list'),
  );

  final Finder scrollableFinder = find.descendant(
    of: messageListFinder,
    matching: find.byType(Scrollable),
  );

  final ScrollableState scrollableState = tester.state<ScrollableState>(
    scrollableFinder,
  );

  scrollableState.position.jumpTo(scrollableState.position.minScrollExtent);

  await tester.pumpAndSettle();
}

void main() {
  testWidgets('first tap shows translating state for five seconds', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());

    await tester.pumpAndSettle();

    await _scrollConversationToStart(tester);

    expect(find.text('欧巴我快要登机了'), findsOneWidget);

    expect(find.text('오빠, 나 곧 탑승해.'), findsNothing);

    await tester.tap(find.text('欧巴我快要登机了'));

    await tester.pump();

    expect(find.text('Translating…'), findsOneWidget);

    expect(find.text('欧巴我快要登机了'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));

    expect(find.text('Translating…'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));

    await tester.pumpAndSettle();

    expect(find.text('Translating…'), findsNothing);

    expect(find.text('오빠, 나 곧 탑승해.'), findsOneWidget);

    await tester.tap(find.text('오빠, 나 곧 탑승해.'));

    await tester.pumpAndSettle();

    expect(find.text('欧巴我快要登机了'), findsOneWidget);

    expect(find.text('오빠, 나 곧 탑승해.'), findsNothing);
  });

  testWidgets(
    'failed translation retry shows translating state for five seconds',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));

      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });

      await tester.pumpWidget(const JuliaTalkPreviewApp());

      await tester.pumpAndSettle();

      expect(find.text('Translation failed: Network error'), findsOneWidget);

      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Retry'));

      await tester.pump();

      expect(find.text('Translating…'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Translation failed: Network error'), findsNothing);

      await tester.pump(const Duration(seconds: 4));

      expect(find.text('Translating…'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));

      await tester.pumpAndSettle();

      expect(find.text('Translating…'), findsNothing);

      expect(find.text('다음에는 제대로 말할게.'), findsOneWidget);
    },
  );

  testWidgets('translated text stays inside the bubble', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());

    await tester.pumpAndSettle();

    await _scrollConversationToStart(tester);

    final Finder bubbleFinder = find.byKey(
      const ValueKey<String>('incoming-bubble-2'),
    );

    await tester.tap(find.text('我等你继续说呢'));

    await tester.pumpAndSettle();

    final Finder translatedTextFinder = find.text('네가 계속 말해주길 기다리고 있어.');

    expect(translatedTextFinder, findsOneWidget);

    final Rect bubbleRect = tester.getRect(bubbleFinder);

    final Rect translatedTextRect = tester.getRect(translatedTextFinder);

    expect(translatedTextRect.left, greaterThanOrEqualTo(bubbleRect.left));

    expect(translatedTextRect.right, lessThanOrEqualTo(bubbleRect.right));

    expect(translatedTextRect.top, greaterThanOrEqualTo(bubbleRect.top));

    expect(translatedTextRect.bottom, lessThanOrEqualTo(bubbleRect.bottom));
  });

  testWidgets('bubble returns to its original size after toggling back', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());

    await tester.pumpAndSettle();

    await _scrollConversationToStart(tester);

    final Finder bubbleFinder = find.byKey(
      const ValueKey<String>('incoming-bubble-2'),
    );

    final Size originalSize = tester.getSize(bubbleFinder);

    await tester.tap(find.text('我等你继续说呢'));

    await tester.pumpAndSettle();

    expect(find.text('네가 계속 말해주길 기다리고 있어.'), findsOneWidget);

    await tester.tap(find.text('네가 계속 말해주길 기다리고 있어.'));

    await tester.pumpAndSettle();

    expect(find.text('我等你继续说呢'), findsOneWidget);

    final Size restoredSize = tester.getSize(bubbleFinder);

    expect(restoredSize.width, closeTo(originalSize.width, 0.01));

    expect(restoredSize.height, closeTo(originalSize.height, 0.01));
  });
}

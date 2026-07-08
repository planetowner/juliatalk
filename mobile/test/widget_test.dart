import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/juliatalk_preview_app.dart';

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
  testWidgets('long conversation opens at the latest message', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    final Finder listFinder = find.byKey(
      const ValueKey<String>('message-list'),
    );

    final Finder scrollableFinder = find.descendant(
      of: listFinder,
      matching: find.byType(Scrollable),
    );

    final ScrollableState scrollableState = tester.state<ScrollableState>(
      scrollableFinder,
    );

    expect(scrollableState.position.maxScrollExtent, greaterThan(0));

    expect(
      scrollableState.position.pixels,
      closeTo(scrollableState.position.maxScrollExtent, 0.5),
    );

    final Finder latestMessageFinder = find.byKey(
      const ValueKey<String>('incoming-bubble-107'),
    );

    expect(latestMessageFinder, findsOneWidget);

    final Rect listRect = tester.getRect(listFinder);

    final Rect latestMessageRect = tester.getRect(latestMessageFinder);

    expect(latestMessageRect.bottom, lessThanOrEqualTo(listRect.bottom + 0.01));
  });

  testWidgets('conversation starts at the top when all messages fit', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 2600));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    final Finder listFinder = find.byKey(
      const ValueKey<String>('message-list'),
    );

    final Finder scrollableFinder = find.descendant(
      of: listFinder,
      matching: find.byType(Scrollable),
    );

    final ScrollableState scrollableState = tester.state<ScrollableState>(
      scrollableFinder,
    );

    expect(scrollableState.position.maxScrollExtent, closeTo(0, 0.01));

    expect(scrollableState.position.pixels, closeTo(0, 0.01));

    final Rect listRect = tester.getRect(listFinder);

    final Finder topBarFinder = find.byKey(
      const ValueKey<String>('chat-top-bar'),
    );

    final Rect topBarRect = tester.getRect(topBarFinder);

    expect(listRect.top, closeTo(0, 0.01));

    final Finder firstDateFinder = find.byKey(
      const ValueKey<String>('chat-date-separator-2026-06-30'),
    );

    final Rect firstDateRect = tester.getRect(firstDateFinder);

    expect(firstDateRect.top - topBarRect.bottom, closeTo(8, 0.01));
  });

  testWidgets('message text and seen receipt remain aligned', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());

    await tester.pumpAndSettle();

    await _scrollConversationToStart(tester);

    final double firstIncomingLeft = tester
        .getTopLeft(find.text('欧巴我快要登机了'))
        .dx;

    final double secondIncomingLeft = tester
        .getTopLeft(find.text('我等你继续说呢'))
        .dx;

    final double firstOutgoingRight = tester
        .getTopRight(find.text('알아 장난이야'))
        .dx;

    final double secondOutgoingRight = tester
        .getTopRight(find.text('타이밍이 웃겨서'))
        .dx;

    final double seenReceiptRight = tester
        .getTopRight(find.text('Seen just now'))
        .dx;

    expect(firstIncomingLeft, closeTo(secondIncomingLeft, 0.01));

    expect(firstOutgoingRight, closeTo(secondOutgoingRight, 0.01));

    expect(seenReceiptRight, closeTo(secondOutgoingRight, 0.01));
  });
}

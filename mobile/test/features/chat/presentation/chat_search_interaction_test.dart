import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/design_system/app_colors.dart';
import 'package:juliatalk/features/chat/domain/chat_message.dart';
import 'package:juliatalk/features/chat/presentation/chat_conversation_view.dart';

Color? _matchBackgroundColor(
  WidgetTester tester, {
  required String messageId,
  required String query,
}) {
  final Finder richTextFinder = find.descendant(
    of: find.byKey(ValueKey<String>('original-message-$messageId')),
    matching: find.byType(RichText),
  );

  Color? findColor(InlineSpan span) {
    if (span is! TextSpan) {
      return null;
    }

    if (span.text == query) {
      return span.style?.backgroundColor;
    }

    for (final InlineSpan child in span.children ?? const <InlineSpan>[]) {
      final Color? color = findColor(child);

      if (color != null) {
        return color;
      }
    }

    return null;
  }

  for (final RichText richText in tester.widgetList<RichText>(richTextFinder)) {
    final Color? color = findColor(richText.text);

    if (color != null) {
      return color;
    }
  }

  return null;
}

void main() {
  testWidgets('search navigation follows KakaoTalk result direction', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: ChatConversationView(
          initialMessages: <ChatMessage>[
            ChatMessage(
              id: 'oldest',
              senderId: '1',
              recipientId: '2',
              content: '자기야 사랑해',
              createdAt: DateTime(2026, 7, 10, 17, 26),
            ),
            ChatMessage(
              id: 'older',
              senderId: '1',
              recipientId: '2',
              content: '자기야 오늘 뭐 먹었어?',
              createdAt: DateTime(2026, 7, 10, 19, 14),
            ),
            ChatMessage(
              id: 'newer',
              senderId: '1',
              recipientId: '2',
              content: '자기야 안녕~~',
              createdAt: DateTime(2026, 7, 10, 19, 47),
            ),
            ChatMessage(
              id: 'newest',
              senderId: '2',
              recipientId: '1',
              content: '안녕 자기야',
              createdAt: DateTime(2026, 7, 10, 19, 48),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Search'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.enterText(
      find.byKey(const ValueKey<String>('chat-search-input')),
      '자기',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('1/4'), findsOneWidget);

    final Finder olderButtonFinder = find.widgetWithIcon(
      IconButton,
      Icons.keyboard_arrow_up_rounded,
    );
    final Finder newerButtonFinder = find.widgetWithIcon(
      IconButton,
      Icons.keyboard_arrow_down_rounded,
    );
    final IconButton upAtNewest = tester.widget<IconButton>(olderButtonFinder);
    final IconButton downAtNewest = tester.widget<IconButton>(
      newerButtonFinder,
    );

    expect(upAtNewest.onPressed, isNotNull);
    expect(downAtNewest.onPressed, isNull);

    final double toolbarCenter = tester
        .getCenter(find.byKey(const ValueKey<String>('chat-search-toolbar')))
        .dx;
    final double counterCenter = tester
        .getCenter(find.byKey(const ValueKey<String>('chat-search-counter')))
        .dx;

    expect(counterCenter, moreOrLessEquals(toolbarCenter, epsilon: 0.5));

    await tester.tap(olderButtonFinder);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('2/4'), findsOneWidget);

    await tester.tap(olderButtonFinder);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(olderButtonFinder);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('4/4'), findsOneWidget);

    final IconButton upAtOldest = tester.widget<IconButton>(olderButtonFinder);
    final IconButton downAtOldest = tester.widget<IconButton>(
      newerButtonFinder,
    );

    expect(upAtOldest.onPressed, isNull);
    expect(downAtOldest.onPressed, isNotNull);

    await tester.tap(newerButtonFinder);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('3/4'), findsOneWidget);
  });

  testWidgets('active outgoing search match has distinct contrast', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ChatConversationView(
          initialMessages: <ChatMessage>[
            ChatMessage(
              id: 'incoming-match',
              senderId: '2',
              recipientId: '1',
              content: '안녕 자기야',
              createdAt: DateTime(2026, 7, 10, 19, 47),
            ),
            ChatMessage(
              id: 'outgoing-match',
              senderId: '1',
              recipientId: '2',
              content: '자기야 안녕~~',
              createdAt: DateTime(2026, 7, 10, 19, 48),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Search'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.enterText(
      find.byKey(const ValueKey<String>('chat-search-input')),
      '자기',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      _matchBackgroundColor(tester, messageId: 'outgoing-match', query: '자기'),
      AppColors.blue900,
    );
    expect(
      _matchBackgroundColor(tester, messageId: 'incoming-match', query: '자기'),
      AppColors.primary.withAlpha(54),
    );

    await tester.tap(
      find.widgetWithIcon(IconButton, Icons.keyboard_arrow_up_rounded),
    );
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      _matchBackgroundColor(tester, messageId: 'incoming-match', query: '자기'),
      AppColors.blue200,
    );
    expect(
      _matchBackgroundColor(tester, messageId: 'outgoing-match', query: '자기'),
      AppColors.white.withAlpha(76),
    );
  });

  testWidgets('search mode preserves the bottom visible message anchor', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() async {
      tester.view.resetViewInsets();
      await tester.binding.setSurfaceSize(null);
    });

    final List<ChatMessage> messages = List<ChatMessage>.generate(
      20,
      (int index) => ChatMessage(
        id: 'anchor-$index',
        senderId: index.isEven ? '1' : '2',
        recipientId: index.isEven ? '2' : '1',
        content: index == 19 ? '你好 宝宝' : 'message $index',
        createdAt: DateTime(2026, 7, 10, 19, index),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(home: ChatConversationView(initialMessages: messages)),
    );
    await tester.pumpAndSettle();

    final Finder anchorBubble = find.byKey(
      const ValueKey<String>('incoming-bubble-anchor-19'),
    );
    final Finder composer = find.byKey(
      const ValueKey<String>('message-composer-default'),
    );

    final double initialGap =
        tester.getTopLeft(composer).dy - tester.getBottomLeft(anchorBubble).dy;

    for (int cycle = 0; cycle < 3; cycle++) {
      await tester.tap(find.byTooltip('Search'));
      await tester.pump(const Duration(milliseconds: 100));

      final Finder searchToolbar = find.byKey(
        const ValueKey<String>('chat-search-toolbar'),
      );

      for (final double keyboardHeight in <double>[60, 120, 180, 240, 300]) {
        tester.view.viewInsets = FakeViewPadding(bottom: keyboardHeight);
        await tester.pump(const Duration(milliseconds: 80));

        final double searchGap =
            tester.getTopLeft(searchToolbar).dy -
            tester.getBottomLeft(anchorBubble).dy;

        expect(
          searchGap,
          moreOrLessEquals(initialGap, epsilon: 1),
          reason:
              'search entry drifted at $keyboardHeight px '
              'on cycle ${cycle + 1}',
        );
      }

      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(milliseconds: 80));

      for (final double keyboardHeight in <double>[240, 180, 120, 60, 0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: keyboardHeight);
        await tester.pump(const Duration(milliseconds: 80));

        final double restoredGap =
            tester.getTopLeft(composer).dy -
            tester.getBottomLeft(anchorBubble).dy;

        expect(
          restoredGap,
          moreOrLessEquals(initialGap, epsilon: 1),
          reason:
              'search exit drifted at $keyboardHeight px '
              'on cycle ${cycle + 1}',
        );
      }
    }
  });

  testWidgets(
    'search results stay hidden until the edited query is submitted',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ChatConversationView(
            currentUserPreferredLanguage: 'ko',
            initialMessages: <ChatMessage>[
              ChatMessage(
                id: 'match',
                senderId: '2',
                recipientId: '1',
                content: '안녕 자기야',
                createdAt: DateTime(2026, 7, 10, 19, 48),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Search'));
      await tester.pump(const Duration(milliseconds: 250));

      final Finder searchInput = find.byKey(
        const ValueKey<String>('chat-search-input'),
      );

      await tester.enterText(searchInput, '자기');
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.byKey(const ValueKey<String>('chat-search-counter')),
        findsNothing,
      );

      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('1/1'), findsOneWidget);

      await tester.tap(searchInput);
      await tester.enterText(searchInput, '없는 검색어');
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('1/1'), findsNothing);
      expect(find.text('검색 결과 없음'), findsNothing);

      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('검색 결과 없음'), findsOneWidget);
      expect(find.text('0/0'), findsNothing);
    },
  );

  testWidgets('empty submitted search uses the Chinese no-results label', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ChatConversationView(currentUserPreferredLanguage: 'zh-CN'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Search'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.enterText(
      find.byKey(const ValueKey<String>('chat-search-input')),
      '没有的内容',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('查无结果'), findsOneWidget);
    expect(find.text('0/0'), findsNothing);
  });
}

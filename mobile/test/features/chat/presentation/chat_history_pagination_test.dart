import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/features/chat/domain/chat_message.dart';
import 'package:juliatalk/features/chat/presentation/chat_conversation_view.dart';

List<ChatMessage> _messages(int start, int end) {
  return List<ChatMessage>.generate(end - start, (int offset) {
    final int index = start + offset;

    return ChatMessage(
      id: 'message-$index',
      senderId: index.isEven ? '1' : '2',
      recipientId: index.isEven ? '2' : '1',
      content: 'message-$index',
      createdAt: DateTime(2026, 7, 1, 10, index),
    );
  });
}

List<ChatMessage> _variableHeightMessages(int count) {
  return List<ChatMessage>.generate(count, (int index) {
    final int lineCount;

    if (index < count ~/ 5) {
      lineCount = 1;
    } else if (index < (count * 2) ~/ 5) {
      lineCount = 2;
    } else if (index < (count * 3) ~/ 5) {
      lineCount = 4;
    } else if (index < (count * 4) ~/ 5) {
      lineCount = 8;
    } else {
      lineCount = 16;
    }

    final String content = List<String>.generate(lineCount, (int line) {
      if (index == count - 1 && line == lineCount - 1) {
        return 'latest-message';
      }

      return 'message-$index line-$line';
    }).join('\n');

    return ChatMessage(
      id: 'variable-message-$index',
      senderId: index.isEven ? '1' : '2',
      recipientId: index.isEven ? '2' : '1',
      content: content,
      createdAt: DateTime(2026, 7, 1, 10).add(Duration(minutes: index)),
    );
  });
}

final class _PaginationHarness extends StatefulWidget {
  const _PaginationHarness({
    required this.firstRequestStarted,
    required this.releaseFirstRequest,
    super.key,
  });

  final Completer<void> firstRequestStarted;
  final Completer<void> releaseFirstRequest;

  @override
  State<_PaginationHarness> createState() => _PaginationHarnessState();
}

final class _PaginationHarnessState extends State<_PaginationHarness> {
  List<ChatMessage> messages = List<ChatMessage>.unmodifiable(
    _messages(100, 160),
  );
  bool hasMoreMessages = true;
  bool loadingOlderMessages = false;
  int loadCount = 0;

  Future<void> _loadOlderMessages() async {
    if (loadingOlderMessages || !hasMoreMessages) {
      return;
    }

    final int requestIndex = loadCount;

    setState(() {
      loadCount++;
      loadingOlderMessages = true;
    });

    if (requestIndex == 0) {
      widget.firstRequestStarted.complete();
      await widget.releaseFirstRequest.future;
    }

    final List<ChatMessage> page = requestIndex == 0
        ? _messages(40, 100)
        : _messages(0, 40);

    setState(() {
      messages = List<ChatMessage>.unmodifiable(<ChatMessage>[
        ...page,
        ...messages,
      ]);
      hasMoreMessages = requestIndex == 0;
      loadingOlderMessages = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: ChatConversationView(
        initialMessages: messages,
        hasMoreMessages: hasMoreMessages,
        loadingOlderMessages: loadingOlderMessages,
        onLoadOlderMessages: _loadOlderMessages,
        initialClock: DateTime(2026, 7, 1, 12),
      ),
    );
  }
}

void main() {
  testWidgets('a recreated cached conversation settles at the actual bottom', (
    WidgetTester tester,
  ) async {
    final List<ChatMessage> messages = _variableHeightMessages(300);

    Widget buildConversation(Key key) {
      return MaterialApp(
        home: ChatConversationView(
          key: key,
          initialMessages: messages,
          initialClock: DateTime(2026, 7, 2),
        ),
      );
    }

    await tester.pumpWidget(
      buildConversation(const ValueKey<String>('first-entry')),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    await tester.pumpWidget(
      buildConversation(const ValueKey<String>('cached-reentry')),
    );
    await tester.pumpAndSettle();

    final Finder listFinder = find.byKey(
      const ValueKey<String>('message-list'),
    );
    final ScrollableState scrollableState = tester.state<ScrollableState>(
      find.descendant(of: listFinder, matching: find.byType(Scrollable)),
    );

    expect(
      scrollableState.position.pixels,
      moreOrLessEquals(scrollableState.position.maxScrollExtent, epsilon: 0.5),
    );
    expect(find.textContaining('latest-message'), findsOneWidget);
  });

  testWidgets(
    'loads every older page while preserving the visible message position',
    (WidgetTester tester) async {
      final Completer<void> firstRequestStarted = Completer<void>();
      final Completer<void> releaseFirstRequest = Completer<void>();
      final GlobalKey<_PaginationHarnessState> harnessKey =
          GlobalKey<_PaginationHarnessState>();

      await tester.pumpWidget(
        _PaginationHarness(
          key: harnessKey,
          firstRequestStarted: firstRequestStarted,
          releaseFirstRequest: releaseFirstRequest,
        ),
      );
      await tester.pumpAndSettle();

      final Finder listFinder = find.byKey(
        const ValueKey<String>('message-list'),
      );

      await tester.drag(listFinder, const Offset(0, 4000));
      await tester.pump();
      await firstRequestStarted.future;
      await tester.pumpAndSettle();

      final Finder anchorMessage = find.text('message-100');
      expect(anchorMessage, findsOneWidget);
      final double anchorTopBefore = tester.getTopLeft(anchorMessage).dy;

      releaseFirstRequest.complete();
      await tester.pumpAndSettle();

      expect(tester.getTopLeft(anchorMessage).dy, closeTo(anchorTopBefore, 1));
      expect(harnessKey.currentState!.loadCount, 1);

      await tester.drag(listFinder, const Offset(0, 4000));
      await tester.pumpAndSettle();

      expect(harnessKey.currentState!.loadCount, 2);
      expect(harnessKey.currentState!.hasMoreMessages, isFalse);

      await tester.drag(listFinder, const Offset(0, 4000));
      await tester.pumpAndSettle();

      expect(find.text('message-0'), findsOneWidget);
      expect(harnessKey.currentState!.loadCount, 2);
    },
  );

  testWidgets(
    'keeps an active drag continuous when an older page is inserted',
    (WidgetTester tester) async {
      final Completer<void> firstRequestStarted = Completer<void>();
      final Completer<void> releaseFirstRequest = Completer<void>();

      await tester.pumpWidget(
        _PaginationHarness(
          firstRequestStarted: firstRequestStarted,
          releaseFirstRequest: releaseFirstRequest,
        ),
      );
      await tester.pumpAndSettle();

      final Finder listFinder = find.byKey(
        const ValueKey<String>('message-list'),
      );

      await tester.drag(listFinder, const Offset(0, 4000));
      await tester.pumpAndSettle();

      expect(
        firstRequestStarted.isCompleted,
        isTrue,
        reason: 'The upward history drag must start the older-page request.',
      );

      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(listFinder),
      );

      await gesture.moveBy(const Offset(0, -60));
      await tester.pump();

      final Finder anchorMessage = find.text('message-100');
      expect(anchorMessage, findsOneWidget);
      final double anchorTopBefore = tester.getTopLeft(anchorMessage).dy;

      releaseFirstRequest.complete();
      await tester.pump();
      await tester.pump();

      expect(tester.getTopLeft(anchorMessage).dy, closeTo(anchorTopBefore, 1));

      final ScrollableState scrollableState = tester.state<ScrollableState>(
        find.descendant(of: listFinder, matching: find.byType(Scrollable)),
      );
      final double scrollOffsetBeforeContinuedDrag =
          scrollableState.position.pixels;

      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();

      expect(
        scrollableState.position.pixels,
        lessThan(scrollOffsetBeforeContinuedDrag - 20),
      );

      await gesture.up();
      await tester.pump(const Duration(milliseconds: 500));
    },
  );
}

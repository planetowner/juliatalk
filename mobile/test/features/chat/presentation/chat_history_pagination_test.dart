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

Animation<double> _messageScrollbarOpacity(WidgetTester tester) {
  final CustomPaint scrollbar = tester.widget<CustomPaint>(
    find.byKey(const ValueKey<String>('message-scrollbar')),
  );
  final dynamic painter = scrollbar.painter;

  return painter.opacity as Animation<double>;
}

double? _retainedMessageScrollbarThumbLength(WidgetTester tester) {
  final CustomPaint scrollbar = tester.widget<CustomPaint>(
    find.byKey(const ValueKey<String>('message-scrollbar')),
  );
  final dynamic painter = scrollbar.painter;
  final dynamic metrics = painter.metricsListenable.value;

  return metrics.retainedThumbLength as double?;
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

final class _NewerPaginationHarness extends StatefulWidget {
  const _NewerPaginationHarness({
    required this.requestStarted,
    required this.releaseRequest,
    super.key,
  });

  final Completer<void> requestStarted;
  final Completer<void> releaseRequest;

  @override
  State<_NewerPaginationHarness> createState() {
    return _NewerPaginationHarnessState();
  }
}

final class _NewerPaginationHarnessState
    extends State<_NewerPaginationHarness> {
  List<ChatMessage> messages = List<ChatMessage>.unmodifiable(_messages(0, 60));
  bool hasMoreNewerMessages = true;
  bool loadingNewerMessages = false;
  int loadCount = 0;

  Future<void> _loadNewerMessages() async {
    if (loadingNewerMessages || !hasMoreNewerMessages) {
      return;
    }

    setState(() {
      loadCount += 1;
      loadingNewerMessages = true;
    });
    widget.requestStarted.complete();
    await widget.releaseRequest.future;

    setState(() {
      messages = List<ChatMessage>.unmodifiable(<ChatMessage>[
        ...messages,
        ..._messages(60, 120),
      ]);
      hasMoreNewerMessages = false;
      loadingNewerMessages = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: ChatConversationView(
        initialMessages: messages,
        hasMoreNewerMessages: hasMoreNewerMessages,
        loadingNewerMessages: loadingNewerMessages,
        onLoadNewerMessages: _loadNewerMessages,
        initialClock: DateTime(2026, 7, 1, 12),
      ),
    );
  }
}

final class _OlderPageAvalancheHarness extends StatefulWidget {
  const _OlderPageAvalancheHarness({super.key});

  @override
  State<_OlderPageAvalancheHarness> createState() {
    return _OlderPageAvalancheHarnessState();
  }
}

final class _OlderPageAvalancheHarnessState
    extends State<_OlderPageAvalancheHarness> {
  List<ChatMessage> messages = List<ChatMessage>.unmodifiable(
    _messages(1000, 1100),
  );
  bool loadingOlderMessages = false;
  int loadCount = 0;

  Future<void> _loadOlderMessages() async {
    if (loadingOlderMessages) {
      return;
    }

    final int pageEnd = 1000 - (loadCount * 100);
    final int pageStart = pageEnd - 100;

    setState(() {
      loadingOlderMessages = true;
    });
    await Future<void>.delayed(Duration.zero);

    setState(() {
      loadCount += 1;
      messages = List<ChatMessage>.unmodifiable(<ChatMessage>[
        ..._messages(pageStart, pageEnd),
        ...messages,
      ]);
      loadingOlderMessages = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: ChatConversationView(
        initialMessages: messages,
        hasMoreMessages: true,
        loadingOlderMessages: loadingOlderMessages,
        onLoadOlderMessages: _loadOlderMessages,
        initialClock: DateTime(2026, 7, 2),
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
    'loads each older page near its stable boundary while preserving position',
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
      expect(
        harnessKey.currentState!.loadCount,
        2,
        reason:
            'The first 60-message page does not fill the six-viewport prefetch '
            'window, so the remaining 40-message page should also be loaded.',
      );

      await tester.drag(listFinder, const Offset(0, 10000));
      await tester.pumpAndSettle();

      expect(harnessKey.currentState!.loadCount, 2);
      expect(harnessKey.currentState!.hasMoreMessages, isFalse);

      await tester.drag(listFinder, const Offset(0, 4000));
      await tester.pumpAndSettle();

      expect(find.text('message-0'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('message-0')).dy,
        lessThan(tester.getTopLeft(find.text('message-1')).dy),
        reason:
            'Lazy history groups must keep chronological visual ordering '
            'before the center sliver.',
      );
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

  testWidgets(
    'does not cascade through older pages before the inserted page is scrolled',
    (WidgetTester tester) async {
      final GlobalKey<_OlderPageAvalancheHarnessState> harnessKey =
          GlobalKey<_OlderPageAvalancheHarnessState>();

      await tester.pumpWidget(_OlderPageAvalancheHarness(key: harnessKey));
      await tester.pumpAndSettle();

      final Finder listFinder = find.byKey(
        const ValueKey<String>('message-list'),
      );
      await tester.drag(listFinder, const Offset(0, 10000));
      await tester.pumpAndSettle();

      expect(
        harnessKey.currentState!.loadCount,
        1,
        reason:
            'A newly prepended 100-message page must move the stable prefetch '
            'boundary away from the viewport instead of triggering the next '
            'page from a stale lazy-sliver extent.',
      );

      await tester.pump(const Duration(milliseconds: 500));
      expect(harnessKey.currentState!.loadCount, 1);
    },
  );

  testWidgets(
    'keeps the visible position stable when a newer page is appended',
    (WidgetTester tester) async {
      final Completer<void> requestStarted = Completer<void>();
      final Completer<void> releaseRequest = Completer<void>();
      final GlobalKey<_NewerPaginationHarnessState> harnessKey =
          GlobalKey<_NewerPaginationHarnessState>();

      await tester.pumpWidget(
        _NewerPaginationHarness(
          key: harnessKey,
          requestStarted: requestStarted,
          releaseRequest: releaseRequest,
        ),
      );
      await tester.pumpAndSettle();

      final Finder listFinder = find.byKey(
        const ValueKey<String>('message-list'),
      );
      await tester.drag(listFinder, const Offset(0, 40));
      await tester.pump();
      await requestStarted.future;

      final Finder anchorMessage = find.text('message-55');
      expect(anchorMessage, findsOneWidget);
      final double anchorTopBefore = tester.getTopLeft(anchorMessage).dy;

      releaseRequest.complete();
      await tester.pump();
      await tester.pump();

      expect(tester.getTopLeft(anchorMessage).dy, closeTo(anchorTopBefore, 1));
      expect(harnessKey.currentState!.loadCount, 1);
      expect(harnessKey.currentState!.hasMoreNewerMessages, isFalse);
    },
  );

  testWidgets(
    'scrolling to latest retains a visible scrollbar before fading it',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ChatConversationView(
            initialMessages: _messages(0, 200),
            initialClock: DateTime(2026, 7, 1, 12),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Finder listFinder = find.byKey(
        const ValueKey<String>('message-list'),
      );
      final Finder latestButtonFinder = find.byKey(
        const ValueKey<String>('scroll-to-latest-message'),
      );

      await tester.drag(listFinder, const Offset(0, 1000));
      await tester.pumpAndSettle();

      final BuildContext listContext = tester.element(listFinder);
      final ScrollableState scrollableState = tester.state<ScrollableState>(
        find.descendant(of: listFinder, matching: find.byType(Scrollable)),
      );
      ScrollStartNotification(
        metrics: scrollableState.position,
        context: listContext,
        dragDetails: DragStartDetails(),
      ).dispatch(listContext);
      await tester.pump(const Duration(milliseconds: 100));

      expect(latestButtonFinder, findsOneWidget);
      expect(_messageScrollbarOpacity(tester).value, closeTo(1, 0.001));
      expect(_retainedMessageScrollbarThumbLength(tester), isNull);

      ScrollEndNotification(
        metrics: scrollableState.position,
        context: listContext,
        dragDetails: DragEndDetails(),
      ).dispatch(listContext);
      await tester.pump();
      await tester.tap(latestButtonFinder);
      await tester.pump();

      final double retainedThumbLength = _retainedMessageScrollbarThumbLength(
        tester,
      )!;

      expect(retainedThumbLength, greaterThan(0));

      await tester.pump(const Duration(milliseconds: 900));

      expect(_messageScrollbarOpacity(tester).value, closeTo(1, 0.001));
      expect(_retainedMessageScrollbarThumbLength(tester), retainedThumbLength);

      await tester.pump(const Duration(milliseconds: 120));

      expect(_messageScrollbarOpacity(tester).value, closeTo(1, 0.001));
      expect(_retainedMessageScrollbarThumbLength(tester), retainedThumbLength);

      await tester.pump(const Duration(milliseconds: 40));

      expect(_messageScrollbarOpacity(tester).value, inExclusiveRange(0, 1));
      expect(_retainedMessageScrollbarThumbLength(tester), retainedThumbLength);

      await tester.pump(const Duration(milliseconds: 260));
      await tester.pump();

      expect(_messageScrollbarOpacity(tester).value, 0);
      expect(_retainedMessageScrollbarThumbLength(tester), isNull);
    },
  );

  testWidgets(
    'scrolling to latest does not revive an already hidden scrollbar',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ChatConversationView(
            initialMessages: _messages(0, 200),
            initialClock: DateTime(2026, 7, 1, 12),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Finder listFinder = find.byKey(
        const ValueKey<String>('message-list'),
      );
      final Finder latestButtonFinder = find.byKey(
        const ValueKey<String>('scroll-to-latest-message'),
      );

      await tester.drag(listFinder, const Offset(0, 1000));
      await tester.pump(const Duration(milliseconds: 800));

      expect(latestButtonFinder, findsOneWidget);
      expect(_messageScrollbarOpacity(tester).value, 0);

      await tester.tap(latestButtonFinder);
      await tester.pump(const Duration(milliseconds: 200));

      expect(_messageScrollbarOpacity(tester).value, 0);
      expect(_retainedMessageScrollbarThumbLength(tester), isNull);
    },
  );

  testWidgets(
    'shows the latest button only after scrolling one screen from the bottom',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ChatConversationView(
            initialMessages: _messages(0, 200),
            initialClock: DateTime(2026, 7, 1, 12),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Finder listFinder = find.byKey(
        const ValueKey<String>('message-list'),
      );
      final Finder latestButtonFinder = find.byKey(
        const ValueKey<String>('scroll-to-latest-message'),
      );
      final ScrollableState scrollableState = tester.state<ScrollableState>(
        find.descendant(of: listFinder, matching: find.byType(Scrollable)),
      );
      final ScrollPosition position = scrollableState.position;
      final double screenHeight = MediaQuery.sizeOf(
        tester.element(listFinder),
      ).height;

      position.jumpTo(position.maxScrollExtent - screenHeight);
      await tester.pump();

      expect(latestButtonFinder, findsNothing);

      position.jumpTo(position.maxScrollExtent - screenHeight - 1);
      await tester.pump();

      expect(latestButtonFinder, findsOneWidget);
    },
  );
}

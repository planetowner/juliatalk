import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juliatalk/core/notifications/notification_service.dart';
import 'package:juliatalk/features/auth/domain/app_user.dart';
import 'package:juliatalk/features/auth/domain/auth_session.dart';
import 'package:juliatalk/features/chat/data/chat_api.dart';
import 'package:juliatalk/features/chat/data/chat_message_cache.dart';
import 'package:juliatalk/features/chat/data/chat_realtime_service.dart';
import 'package:juliatalk/features/chat/presentation/chat_conversation_screen.dart';
import 'package:juliatalk/features/chat/presentation/chat_conversation_view.dart';

const AppUser _currentUser = AppUser(
  id: 'current-user',
  username: 'current',
  displayName: 'Current',
  preferredLanguage: 'ko',
);

const AppUser _otherUser = AppUser(
  id: 'other-user',
  username: 'other',
  displayName: 'Other',
  preferredLanguage: 'en',
);

ScrollView _messageList(WidgetTester tester) {
  return tester.widget<ScrollView>(
    find.byKey(const ValueKey<String>('message-list')),
  );
}

Map<String, dynamic> _messageJson(int index, {int? replyToIndex}) {
  return <String, dynamic>{
    'id': 'message-$index',
    'sender_id': index.isEven ? _currentUser.id : _otherUser.id,
    'recipient_id': index.isEven ? _otherUser.id : _currentUser.id,
    'content': 'message-$index',
    'created_at': DateTime.utc(
      2026,
      7,
      1,
    ).add(Duration(minutes: index)).toIso8601String(),
    'edited_at': null,
    'read_at': null,
    'translation_status': 'completed',
    'translated_content': 'translated-message-$index',
    'source_language': 'en',
    'translated_language': 'ko',
    'reply_to': replyToIndex == null
        ? null
        : <String, dynamic>{
            'message_id': 'message-$replyToIndex',
            'sender_id': replyToIndex.isEven ? _currentUser.id : _otherUser.id,
            'content': 'message-$replyToIndex',
          },
    'message_type': 'text',
  };
}

Future<ChatRealtimeService> _pumpConversationHome(
  WidgetTester tester, {
  Future<http.Response> Function(http.Request request)? conversationResponder,
  Future<http.Response> Function(http.Request request)? messageResponder,
}) async {
  final MockClient client = MockClient((http.Request request) async {
    if (request.method == 'GET' && request.url.path == '/users') {
      return http.Response(
        jsonEncode(<Map<String, dynamic>>[_otherUser.toJson()]),
        200,
        headers: const <String, String>{'content-type': 'application/json'},
      );
    }

    if (request.method == 'GET' &&
        (request.url.path == '/messages/conversation/${_otherUser.id}' ||
            request.url.path.startsWith(
              '/messages/conversation/${_otherUser.id}/around/',
            ))) {
      if (conversationResponder != null) {
        return conversationResponder(request);
      }

      return http.Response(
        '[]',
        200,
        headers: const <String, String>{'content-type': 'application/json'},
      );
    }

    if (request.method == 'PATCH' &&
        request.url.path == '/messages/conversation/${_otherUser.id}/read') {
      return http.Response('{}', 200);
    }

    if (request.method == 'POST' && request.url.path == '/messages') {
      if (messageResponder != null) {
        return messageResponder(request);
      }

      throw StateError('Unexpected message send request: ${request.url}');
    }

    if (request.method == 'GET' &&
        request.url.path == '/messages/unread-counts') {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'counts_by_sender_id': <String, int>{},
          'total_unread_count': 0,
        }),
        200,
        headers: const <String, String>{'content-type': 'application/json'},
      );
    }

    throw StateError('Unexpected request: ${request.method} ${request.url}');
  });
  final Uri baseUri = Uri.parse('https://api.example.com');
  final ChatApi chatApi = ChatApi(
    client: client,
    baseUri: baseUri,
    accessToken: 'test-token',
  );
  final AuthSession session = AuthSession(
    accessToken: 'test-token',
    tokenType: 'bearer',
    user: _currentUser,
  );
  final ChatMessageCache messageCache = ChatMessageCache(
    chatApi: chatApi,
    currentUserId: _currentUser.id,
    persistenceEnabled: false,
  );
  final ChatRealtimeService realtimeService = ChatRealtimeService(
    chatApi: chatApi,
    baseUri: baseUri,
    session: session,
    notificationService: NotificationService(),
  );

  await tester.pumpWidget(
    MaterialApp(
      home: ChatConversationHomeScreen(
        chatApi: chatApi,
        realtimeService: realtimeService,
        session: session,
        controller: ChatConversationHomeController(),
        messageCache: messageCache,
      ),
    ),
  );
  await tester.pumpAndSettle();

  return realtimeService;
}

Future<ChatRealtimeService> _pumpOpenConversation(WidgetTester tester) async {
  final ChatRealtimeService realtimeService = await _pumpConversationHome(
    tester,
  );

  await tester.tap(find.text(_otherUser.displayName));
  await tester.pumpAndSettle();

  expect(find.byKey(const ValueKey<String>('message-list')), findsOneWidget);

  return realtimeService;
}

Future<TestGesture> _startRouteGesture(WidgetTester tester, Finder listFinder) {
  final Rect listRect = tester.getRect(listFinder);

  return tester.startGesture(Offset(listRect.left + 24, listRect.center.dy));
}

Future<void> _moveRouteGestureSlowly(
  WidgetTester tester,
  TestGesture gesture, {
  required double distance,
}) async {
  const int steps = 8;
  final double stepDistance = distance / steps;

  for (int step = 0; step < steps; step++) {
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(Offset(stepDistance, 0));
  }

  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets(
    'a paginated conversation reenters with a bounded latest-message cache',
    (WidgetTester tester) async {
      int olderPageRequestCount = 0;

      final ChatRealtimeService realtimeService = await _pumpConversationHome(
        tester,
        conversationResponder: (http.Request request) async {
          final String? beforeMessageId =
              request.url.queryParameters['before_message_id'];

          if (beforeMessageId == null) {
            return http.Response(
              jsonEncode(
                List<Map<String, dynamic>>.generate(
                  100,
                  (int index) => _messageJson(index + 100),
                ),
              ),
              200,
              headers: const <String, String>{
                'content-type': 'application/json',
                'x-has-more': 'true',
              },
            );
          }

          expect(beforeMessageId, 'message-100');
          expect(request.url.queryParameters['limit'], '100');
          olderPageRequestCount++;

          return http.Response(
            jsonEncode(List<Map<String, dynamic>>.generate(100, _messageJson)),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
              'x-has-more': 'false',
            },
          );
        },
      );
      addTearDown(realtimeService.dispose);

      Future<void> openConversation() async {
        await tester.tap(find.text(_otherUser.displayName));
        await tester.pumpAndSettle();
      }

      Future<void> loadOlderPage() async {
        final Finder listFinder = find.byKey(
          const ValueKey<String>('message-list'),
        );
        await tester.drag(listFinder, const Offset(0, 10000));
        await tester.pumpAndSettle();
      }

      await openConversation();
      await loadOlderPage();

      expect(olderPageRequestCount, 1);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      await openConversation();
      await loadOlderPage();

      expect(
        olderPageRequestCount,
        2,
        reason:
            'Reentry should keep only the latest page and reload older history '
            'on demand.',
      );
    },
  );

  testWidgets(
    'a cached conversation starts sliding immediately after its first frame',
    (WidgetTester tester) async {
      final ChatRealtimeService realtimeService = await _pumpConversationHome(
        tester,
      );
      addTearDown(realtimeService.dispose);

      final double width = tester
          .getSize(find.byType(ChatConversationHomeScreen))
          .width;

      await tester.tap(find.text(_otherUser.displayName));

      // Advance past the entire route duration in the first build frame. The
      // animation must start after that frame instead of being consumed by it.
      await tester.pump(const Duration(milliseconds: 190));

      final Finder routeTransformFinder = find.byKey(
        const ValueKey<String>('chat-route-transform'),
      );

      double routeOffset() {
        return tester
            .widget<Transform>(routeTransformFinder)
            .transform
            .getTranslation()
            .x;
      }

      expect(routeOffset(), moreOrLessEquals(width, epsilon: 0.5));

      for (int frame = 0; frame < 10 && routeOffset() >= width - 0.5; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(routeOffset(), greaterThan(0));
      expect(routeOffset(), lessThan(width));

      await tester.pumpAndSettle();

      expect(routeOffset(), moreOrLessEquals(0, epsilon: 0.5));
    },
  );

  testWidgets(
    'a transient older-page failure retries without another user drag',
    (WidgetTester tester) async {
      int olderPageRequestCount = 0;
      final ChatRealtimeService realtimeService = await _pumpConversationHome(
        tester,
        conversationResponder: (http.Request request) async {
          final String? beforeMessageId =
              request.url.queryParameters['before_message_id'];

          if (beforeMessageId == null) {
            return http.Response(
              jsonEncode(
                List<Map<String, dynamic>>.generate(
                  100,
                  (int index) => _messageJson(index + 100),
                ),
              ),
              200,
              headers: const <String, String>{
                'content-type': 'application/json',
                'x-has-more': 'true',
              },
            );
          }

          expect(beforeMessageId, 'message-100');
          olderPageRequestCount += 1;

          if (olderPageRequestCount == 1) {
            return http.Response('{}', 503);
          }

          return http.Response(
            jsonEncode(List<Map<String, dynamic>>.generate(100, _messageJson)),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
              'x-has-more': 'false',
            },
          );
        },
      );
      addTearDown(realtimeService.dispose);

      await tester.tap(find.text(_otherUser.displayName));
      await tester.pumpAndSettle();

      final Finder listFinder = find.byKey(
        const ValueKey<String>('message-list'),
      );
      await tester.drag(listFinder, const Offset(0, 10000));
      await tester.pump();

      expect(olderPageRequestCount, 1);

      await tester.pump(const Duration(milliseconds: 399));
      expect(olderPageRequestCount, 1);

      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();

      expect(olderPageRequestCount, 2);
      final ChatConversationView conversationView = tester
          .widget<ChatConversationView>(find.byType(ChatConversationView));
      expect(conversationView.initialMessages, hasLength(200));
      expect(conversationView.initialMessages!.first.id, 'message-0');
      expect(conversationView.initialMessages!.last.id, 'message-199');
      expect(olderPageRequestCount, 2);
    },
  );

  testWidgets(
    'a reply quote loads its original outside the latest cached page',
    (WidgetTester tester) async {
      int contextRequestCount = 0;
      final ChatRealtimeService realtimeService = await _pumpConversationHome(
        tester,
        messageResponder: (http.Request request) async {
          final Map<String, dynamic> requestBody =
              jsonDecode(request.body) as Map<String, dynamic>;
          final Map<String, dynamic> sentMessage = _messageJson(400);
          sentMessage['content'] = requestBody['content'];

          return http.Response(
            jsonEncode(sentMessage),
            201,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        },
        conversationResponder: (http.Request request) async {
          if (request.url.path.contains('/around/')) {
            contextRequestCount += 1;
            final String targetMessageId = request.url.pathSegments.last;
            final int targetIndex = int.parse(
              targetMessageId.substring('message-'.length),
            );
            final int startIndex = targetIndex == 21 ? 0 : 369;
            final int endIndex = targetIndex == 21 ? 52 : 400;

            expect(request.url.queryParameters['older_limit'], '30');
            expect(request.url.queryParameters['newer_limit'], '30');

            return http.Response(
              jsonEncode(<String, Object?>{
                'messages': List<Map<String, dynamic>>.generate(
                  endIndex - startIndex,
                  (int offset) {
                    final int index = startIndex + offset;
                    return _messageJson(
                      index,
                      replyToIndex: index == 399 ? 21 : null,
                    );
                  },
                ),
                'has_more_older': startIndex > 0,
                'has_more_newer': endIndex < 400,
              }),
              200,
              headers: const <String, String>{
                'content-type': 'application/json',
              },
            );
          }

          final String? beforeMessageId =
              request.url.queryParameters['before_message_id'];

          if (beforeMessageId == null) {
            return http.Response(
              jsonEncode(
                List<Map<String, dynamic>>.generate(100, (int offset) {
                  final int index = offset + 300;

                  return _messageJson(
                    index,
                    replyToIndex: index == 399 ? 21 : null,
                  );
                }),
              ),
              200,
              headers: const <String, String>{
                'content-type': 'application/json',
                'x-has-more': 'true',
              },
            );
          }

          throw StateError('Reply navigation must use the context endpoint.');
        },
      );
      addTearDown(realtimeService.dispose);

      await tester.tap(find.text(_otherUser.displayName));
      await tester.pumpAndSettle();

      final Finder quoteAreaFinder = find.byKey(
        const ValueKey<String>('reply-quote-area-message-399'),
      );
      expect(quoteAreaFinder, findsOneWidget);

      final Finder messageListFinder = find.byKey(
        const ValueKey<String>('message-list'),
      );
      final Rect initialMessageListRect = tester.getRect(messageListFinder);
      final double initialReplyTop =
          tester.getRect(quoteAreaFinder).top - initialMessageListRect.top;

      await tester.tap(quoteAreaFinder);

      final Finder originalBubbleFinder = find.byKey(
        const ValueKey<String>('incoming-bubble-message-21'),
      );
      final Finder backButtonFinder = find.byKey(
        const ValueKey<String>('back-to-reply-message'),
      );

      for (
        int frame = 0;
        frame < 80 && backButtonFinder.evaluate().isEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 40));
      }

      expect(contextRequestCount, 1);
      expect(originalBubbleFinder, findsOneWidget);
      expect(backButtonFinder, findsOneWidget);

      final Rect messageListRect = tester.getRect(
        find.byKey(const ValueKey<String>('message-list')),
      );
      final Rect originalBubbleRect = tester.getRect(originalBubbleFinder);
      final double originalTopRatio =
          (originalBubbleRect.top - messageListRect.top) /
          messageListRect.height;

      // RenderAbstractViewport may settle on a fractional physical pixel.
      // Keep the expected placement band while allowing that subpixel rounding.
      expect(originalTopRatio, inInclusiveRange(0.18, 0.39));

      await tester.tap(backButtonFinder);

      for (
        int frame = 0;
        frame < 80 && backButtonFinder.evaluate().isNotEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 40));
      }

      expect(backButtonFinder, findsNothing);
      expect(quoteAreaFinder, findsOneWidget);
      expect(contextRequestCount, 2);

      final Rect returnedMessageListRect = tester.getRect(messageListFinder);
      final double returnedReplyTop =
          tester.getRect(quoteAreaFinder).top - returnedMessageListRect.top;

      expect(returnedReplyTop, closeTo(initialReplyTop, 1));

      await tester.enterText(
        find.byKey(const ValueKey<String>('message-input')),
        'sent after reply navigation',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('message-send')));
      await tester.pumpAndSettle();

      final Finder newestBubbleFinder = find.byKey(
        const ValueKey<String>('outgoing-bubble-message-400'),
      );
      final Finder composerFinder = find.byKey(
        const ValueKey<String>('message-composer-default'),
      );

      expect(newestBubbleFinder, findsOneWidget);
      expect(
        tester.getRect(composerFinder).top -
            tester.getRect(newestBubbleFinder).bottom,
        closeTo(12, 1),
        reason:
            'Returning from reply navigation must not leave its recentered '
            'sliver as the structural center of the latest conversation.',
      );
    },
  );

  testWidgets(
    'a gesture that starts vertically never becomes a back swipe later',
    (WidgetTester tester) async {
      final ChatRealtimeService realtimeService = await _pumpOpenConversation(
        tester,
      );
      addTearDown(realtimeService.dispose);

      final Finder listFinder = find.byKey(
        const ValueKey<String>('message-list'),
      );
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(listFinder),
      );

      await gesture.moveBy(const Offset(0, 20));
      await tester.pump();
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();

      expect(
        _messageList(tester).physics,
        isNot(isA<NeverScrollableScrollPhysics>()),
      );

      await gesture.up();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'a cancelled back swipe stays locked until its return animation ends',
    (WidgetTester tester) async {
      final ChatRealtimeService realtimeService = await _pumpOpenConversation(
        tester,
      );
      addTearDown(realtimeService.dispose);

      final Finder listFinder = find.byKey(
        const ValueKey<String>('message-list'),
      );
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(listFinder),
      );

      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();

      expect(_messageList(tester).physics, isA<NeverScrollableScrollPhysics>());

      await gesture.up();
      await tester.pump();

      expect(_messageList(tester).physics, isA<NeverScrollableScrollPhysics>());

      await tester.pump(const Duration(milliseconds: 100));

      expect(_messageList(tester).physics, isA<NeverScrollableScrollPhysics>());

      await tester.pumpAndSettle();

      expect(
        _messageList(tester).physics,
        isNot(isA<NeverScrollableScrollPhysics>()),
      );
    },
  );

  testWidgets('a slow held drag below halfway returns to the conversation', (
    WidgetTester tester,
  ) async {
    final ChatRealtimeService realtimeService = await _pumpOpenConversation(
      tester,
    );
    addTearDown(realtimeService.dispose);

    final Finder listFinder = find.byKey(
      const ValueKey<String>('message-list'),
    );
    final double width = tester.getSize(listFinder).width;
    final TestGesture gesture = await _startRouteGesture(tester, listFinder);

    await _moveRouteGestureSlowly(tester, gesture, distance: width * 0.49);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(listFinder, findsOneWidget);
    expect(
      _messageList(tester).physics,
      isNot(isA<NeverScrollableScrollPhysics>()),
    );
  });

  testWidgets('a slow held drag at halfway closes the conversation', (
    WidgetTester tester,
  ) async {
    final ChatRealtimeService realtimeService = await _pumpOpenConversation(
      tester,
    );
    addTearDown(realtimeService.dispose);

    final Finder listFinder = find.byKey(
      const ValueKey<String>('message-list'),
    );
    final double width = tester.getSize(listFinder).width;
    final TestGesture gesture = await _startRouteGesture(tester, listFinder);

    await _moveRouteGestureSlowly(tester, gesture, distance: width * 0.5);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(listFinder, findsNothing);
  });

  testWidgets('a fast right flick closes before reaching halfway', (
    WidgetTester tester,
  ) async {
    final ChatRealtimeService realtimeService = await _pumpOpenConversation(
      tester,
    );
    addTearDown(realtimeService.dispose);

    final Finder listFinder = find.byKey(
      const ValueKey<String>('message-list'),
    );
    final double stepDistance = tester.getSize(listFinder).width * 0.05;
    final TestGesture gesture = await _startRouteGesture(tester, listFinder);

    for (int step = 0; step < 4; step++) {
      final Duration timeStamp = Duration(milliseconds: (step + 1) * 10);
      await tester.pump(const Duration(milliseconds: 10));
      await gesture.moveBy(Offset(stepDistance, 0), timeStamp: timeStamp);
    }

    await gesture.up(timeStamp: const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(listFinder, findsNothing);
  });
}

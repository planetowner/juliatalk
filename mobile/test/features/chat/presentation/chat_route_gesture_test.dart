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
    refreshToken: 'test-refresh-token',
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

      // 첫 빌드 프레임에서 전환 시간을 모두 흘려도 애니메이션은 다음 프레임부터 시작해야 해요.
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
      int sentMessageCount = 0;
      final DateTime sentAt = DateTime.utc(2026, 7, 1, 7);
      final ChatRealtimeService realtimeService = await _pumpConversationHome(
        tester,
        messageResponder: (http.Request request) async {
          sentMessageCount += 1;
          final Map<String, dynamic> requestBody =
              jsonDecode(request.body) as Map<String, dynamic>;
          final Map<String, dynamic> sentMessage = _messageJson(
            399 + sentMessageCount,
          );
          sentMessage['content'] = requestBody['content'];
          sentMessage['created_at'] = sentAt.toIso8601String();
          sentMessage['sender_id'] = _currentUser.id;
          sentMessage['recipient_id'] = _otherUser.id;

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
      final Finder latestButtonFinder = find.byKey(
        const ValueKey<String>('scroll-to-latest-message'),
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
      expect(latestButtonFinder, findsOneWidget);

      final Rect messageListRect = tester.getRect(
        find.byKey(const ValueKey<String>('message-list')),
      );
      final Rect originalBubbleRect = tester.getRect(originalBubbleFinder);
      final double originalTopRatio =
          (originalBubbleRect.top - messageListRect.top) /
          messageListRect.height;

      // RenderAbstractViewport의 물리 픽셀 반올림 오차는 허용하되 기대 위치 범위는 지켜요.
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
      expect(
        contextRequestCount,
        1,
        reason:
            'Returning to a reply captured from the latest window must reuse '
            'that complete window instead of requesting a 30-message context.',
      );

      final Rect returnedMessageListRect = tester.getRect(messageListFinder);
      final double returnedReplyTop =
          tester.getRect(quoteAreaFinder).top - returnedMessageListRect.top;

      expect(returnedReplyTop, closeTo(initialReplyTop, 1));

      await tester.drag(messageListFinder, const Offset(0, -500));
      await tester.pumpAndSettle();

      final Finder returnedLatestBubbleFinder = find.byKey(
        const ValueKey<String>('incoming-bubble-message-399'),
      );
      final Finder composerFinder = find.byKey(
        const ValueKey<String>('message-composer-default'),
      );

      expect(returnedLatestBubbleFinder, findsOneWidget);
      expect(
        tester.getRect(composerFinder).top -
            tester.getRect(returnedLatestBubbleFinder).bottom,
        closeTo(12, 1),
        reason:
            'Returning to the actual last reply must restore the latest '
            'structural center so no empty space can be scrolled below it.',
      );

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
      expect(newestBubbleFinder, findsOneWidget);
      expect(
        tester.getRect(composerFinder).top -
            tester.getRect(newestBubbleFinder).bottom,
        closeTo(12, 1),
        reason:
            'Returning from reply navigation must not leave its recentered '
            'sliver as the structural center of the latest conversation.',
      );

      for (final String content in <String>[
        'second message in the same minute',
        'third message in the same minute',
      ]) {
        await tester.enterText(
          find.byKey(const ValueKey<String>('message-input')),
          content,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey<String>('message-send')));
        await tester.pumpAndSettle();
      }

      final BuildContext timestampContext = tester.element(composerFinder);
      final String formattedSentTime =
          MaterialLocalizations.of(timestampContext).formatTimeOfDay(
            TimeOfDay.fromDateTime(sentAt.toLocal()),
            alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(
              timestampContext,
            ),
          );

      expect(find.text(formattedSentTime), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('outgoing-bubble-message-402')),
        findsOneWidget,
      );

      await tester.tap(quoteAreaFinder);

      for (
        int frame = 0;
        frame < 80 && latestButtonFinder.evaluate().isEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 40));
      }

      expect(backButtonFinder, findsOneWidget);
      expect(latestButtonFinder, findsOneWidget);

      await tester.tap(latestButtonFinder);
      await tester.pumpAndSettle();

      expect(backButtonFinder, findsNothing);
      expect(latestButtonFinder, findsNothing);
      expect(newestBubbleFinder, findsOneWidget);
    },
  );

  testWidgets(
    'a cached far reply restores the original history center before scrolling',
    (WidgetTester tester) async {
      final ChatRealtimeService realtimeService = await _pumpConversationHome(
        tester,
        conversationResponder: (http.Request request) async {
          final List<Map<String, dynamic>> messages =
              List<Map<String, dynamic>>.generate(100, (int offset) {
                final int index = offset + 300;

                return _messageJson(
                  index,
                  replyToIndex: index == 399 ? 300 : null,
                );
              });

          if (request.url.path.contains('/around/')) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'messages': messages,
                'has_more_older': true,
                'has_more_newer': false,
              }),
              200,
              headers: const <String, String>{
                'content-type': 'application/json',
              },
            );
          }

          return http.Response(
            jsonEncode(messages),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
              'x-has-more': 'true',
            },
          );
        },
      );
      addTearDown(realtimeService.dispose);

      await tester.tap(find.text(_otherUser.displayName));
      await tester.pumpAndSettle();

      final Finder quoteAreaFinder = find.byKey(
        const ValueKey<String>('reply-quote-area-message-399'),
      );
      final Finder messageListFinder = find.byKey(
        const ValueKey<String>('message-list'),
      );
      final Finder backButtonFinder = find.byKey(
        const ValueKey<String>('back-to-reply-message'),
      );

      expect(quoteAreaFinder, findsOneWidget);

      await tester.tap(quoteAreaFinder);

      for (
        int frame = 0;
        frame < 40 && backButtonFinder.evaluate().isEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 40));
      }

      expect(backButtonFinder, findsOneWidget);

      await tester.tap(backButtonFinder);

      for (
        int frame = 0;
        frame < 40 && backButtonFinder.evaluate().isNotEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 40));
      }

      expect(backButtonFinder, findsNothing);

      await tester.drag(messageListFinder, const Offset(0, -500));
      await tester.pumpAndSettle();

      final Finder latestBubbleFinder = find.byKey(
        const ValueKey<String>('incoming-bubble-message-399'),
      );
      final Finder composerFinder = find.byKey(
        const ValueKey<String>('message-composer-default'),
      );

      expect(latestBubbleFinder, findsOneWidget);
      expect(
        tester.getRect(composerFinder).top -
            tester.getRect(latestBubbleFinder).bottom,
        closeTo(12, 1),
        reason:
            'Returning from a cached far reply must restore the latest '
            'conversation center so the list cannot scroll into empty space.',
      );
    },
  );

  testWidgets(
    'manual scrolling dismisses reply return but keeps the latest action',
    (WidgetTester tester) async {
      final ChatRealtimeService realtimeService = await _pumpConversationHome(
        tester,
        conversationResponder: (http.Request request) async {
          final List<Map<String, dynamic>> messages =
              List<Map<String, dynamic>>.generate(100, (int offset) {
                final int index = offset + 300;

                return _messageJson(
                  index,
                  replyToIndex: index == 399 ? 300 : null,
                );
              });

          if (request.url.path.contains('/around/')) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'messages': messages,
                'has_more_older': true,
                'has_more_newer': false,
              }),
              200,
              headers: const <String, String>{
                'content-type': 'application/json',
              },
            );
          }

          return http.Response(
            jsonEncode(messages),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
              'x-has-more': 'true',
            },
          );
        },
      );
      addTearDown(realtimeService.dispose);

      await tester.tap(find.text(_otherUser.displayName));
      await tester.pumpAndSettle();

      final Finder quoteAreaFinder = find.byKey(
        const ValueKey<String>('reply-quote-area-message-399'),
      );
      final Finder messageListFinder = find.byKey(
        const ValueKey<String>('message-list'),
      );
      final Finder backButtonFinder = find.byKey(
        const ValueKey<String>('back-to-reply-message'),
      );
      final Finder latestButtonFinder = find.byKey(
        const ValueKey<String>('scroll-to-latest-message'),
      );
      final Finder dateBubbleFinder = find.byKey(
        const ValueKey<String>('message-scroll-date-bubble'),
      );

      await tester.tap(quoteAreaFinder);

      for (
        int frame = 0;
        frame < 40 && backButtonFinder.evaluate().isEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 40));
      }

      expect(backButtonFinder, findsOneWidget);
      expect(latestButtonFinder, findsOneWidget);

      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(messageListFinder),
      );
      await gesture.moveBy(const Offset(0, -90));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        dateBubbleFinder,
        findsOneWidget,
        reason: 'The date bubble should begin appearing with the first drag.',
      );

      await gesture.moveBy(const Offset(0, -30));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pump(const Duration(milliseconds: 100));

      expect(backButtonFinder, findsNothing);
      expect(latestButtonFinder, findsOneWidget);
      expect(dateBubbleFinder, findsOneWidget);
      expect(tester.getSize(dateBubbleFinder).height, closeTo(24, 0.01));
      expect(
        tester.getRect(messageListFinder).right -
            tester.getRect(dateBubbleFinder).right,
        closeTo(8, 0.01),
      );
      final DecoratedBox dateBubble = tester.widget<DecoratedBox>(
        dateBubbleFinder,
      );
      expect(
        (dateBubble.decoration as BoxDecoration).color,
        const Color.fromARGB(105, 0, 0, 0),
      );

      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump(const Duration(milliseconds: 140));

      expect(
        dateBubbleFinder,
        findsOneWidget,
        reason:
            'The date bubble should fade out instead of disappearing early.',
      );

      await tester.pump(const Duration(milliseconds: 40));
      await tester.pumpAndSettle();

      expect(dateBubbleFinder, findsNothing);
      expect(latestButtonFinder, findsOneWidget);

      await tester.tap(latestButtonFinder);

      for (
        int frame = 0;
        frame < 40 && latestButtonFinder.evaluate().isNotEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 40));
      }

      await tester.pumpAndSettle();

      expect(latestButtonFinder, findsNothing);
      expect(
        find.byKey(const ValueKey<String>('incoming-bubble-message-399')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'drag dismissing the keyboard preserves the message viewport anchor',
    (WidgetTester tester) async {
      final ChatRealtimeService realtimeService = await _pumpConversationHome(
        tester,
        conversationResponder: (http.Request request) async {
          return http.Response(
            jsonEncode(
              List<Map<String, dynamic>>.generate(
                100,
                (int offset) => _messageJson(offset + 300),
              ),
            ),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
              'x-has-more': 'true',
            },
          );
        },
      );
      addTearDown(realtimeService.dispose);
      addTearDown(tester.view.resetViewInsets);

      await tester.tap(find.text(_otherUser.displayName));
      await tester.pumpAndSettle();

      final Finder messageListFinder = find.byKey(
        const ValueKey<String>('message-list'),
      );
      final Finder latestBubbleFinder = find.byKey(
        const ValueKey<String>('incoming-bubble-message-399'),
      );
      final Finder composerFinder = find.byKey(
        const ValueKey<String>('message-composer-default'),
      );
      final Finder inputFinder = find.byKey(
        const ValueKey<String>('message-input'),
      );

      await tester.tap(inputFinder);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();

      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(messageListFinder),
      );
      await gesture.moveBy(const Offset(0, 24));
      await tester.pump();

      tester.view.viewInsets = const FakeViewPadding();

      for (int frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      await gesture.up();
      await tester.pumpAndSettle();

      expect(latestBubbleFinder, findsOneWidget);
      expect(
        tester.getRect(composerFinder).top -
            tester.getRect(latestBubbleFinder).bottom,
        closeTo(12, 1),
        reason:
            'A drag that dismisses the keyboard must not leave a '
            'keyboard-height blank region below the latest message.',
      );
    },
  );

  testWidgets(
    'bottom surface resizing preserves a scrolled message viewport anchor',
    (WidgetTester tester) async {
      final ChatRealtimeService realtimeService = await _pumpConversationHome(
        tester,
        conversationResponder: (http.Request request) async {
          return http.Response(
            jsonEncode(
              List<Map<String, dynamic>>.generate(
                100,
                (int offset) => _messageJson(offset + 300),
              ),
            ),
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
              'x-has-more': 'true',
            },
          );
        },
      );
      addTearDown(realtimeService.dispose);
      addTearDown(tester.view.resetViewInsets);

      await tester.tap(find.text(_otherUser.displayName));
      await tester.pumpAndSettle();

      final ScrollController scrollController = _messageList(
        tester,
      ).controller!;
      scrollController.jumpTo(
        (scrollController.position.minScrollExtent +
                scrollController.position.maxScrollExtent) /
            2,
      );
      await tester.pump();

      expect(
        scrollController.position.maxScrollExtent -
            scrollController.position.pixels,
        greaterThan(48),
      );

      final double pixelsBeforeKeyboard = scrollController.position.pixels;
      final double devicePixelRatio = tester.view.devicePixelRatio;

      await tester.tap(find.byKey(const ValueKey<String>('message-input')));

      tester.view.viewInsets = FakeViewPadding(bottom: 300 * devicePixelRatio);
      await tester.pump(const Duration(milliseconds: 16));

      final double pixelsAtStableKeyboardHeight =
          scrollController.position.pixels;

      for (final double keyboardHeight in const <double>[
        300.843,
        300.708,
        300.594,
        300.498,
        300.417,
        300.350,
        300.293,
        300.000,
      ]) {
        tester.view.viewInsets = FakeViewPadding(
          bottom: keyboardHeight * devicePixelRatio,
        );
        await tester.pump(const Duration(milliseconds: 8));
      }

      expect(
        scrollController.position.pixels,
        closeTo(pixelsAtStableKeyboardHeight, 0.01),
        reason:
            'Sub-pixel keyboard animation frames must not accumulate into '
            'message viewport drift.',
      );

      tester.view.viewInsets = const FakeViewPadding();
      await tester.pumpAndSettle();

      expect(
        scrollController.position.pixels,
        closeTo(pixelsBeforeKeyboard, 0.01),
      );

      for (int cycle = 0; cycle < 6; cycle += 1) {
        final double viewportBeforeKeyboard =
            scrollController.position.viewportDimension;

        tester.view.viewInsets = FakeViewPadding(
          bottom: 300 * devicePixelRatio,
        );
        await tester.pumpAndSettle();

        final double keyboardViewportChange =
            viewportBeforeKeyboard -
            scrollController.position.viewportDimension;

        expect(keyboardViewportChange, greaterThan(0));
        expect(
          scrollController.position.pixels - pixelsBeforeKeyboard,
          closeTo(keyboardViewportChange, 1),
          reason:
              'Opening the keyboard must move the current message viewport by '
              'the same amount that its visible height shrinks.',
        );

        tester.view.viewInsets = const FakeViewPadding();
        await tester.pumpAndSettle();

        expect(
          scrollController.position.pixels,
          closeTo(pixelsBeforeKeyboard, 0.01),
          reason:
              'Keyboard cycle ${cycle + 1} must restore the same message '
              'viewport without cumulative drift.',
        );
      }

      final double pixelsBeforePanel = scrollController.position.pixels;
      final double viewportBeforePanel =
          scrollController.position.viewportDimension;

      await tester.tap(
        find.byKey(const ValueKey<String>('message-attachment')),
      );
      await tester.pumpAndSettle();

      final double panelViewportChange =
          viewportBeforePanel - scrollController.position.viewportDimension;

      expect(panelViewportChange, greaterThan(0));
      expect(
        scrollController.position.pixels - pixelsBeforePanel,
        closeTo(panelViewportChange, 0.01),
        reason:
            'The attachment panel must use the same viewport resize rule as '
            'the system keyboard.',
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('message-attachment')),
      );

      tester.view.viewInsets = FakeViewPadding(bottom: 320 * devicePixelRatio);
      await tester.pumpAndSettle();

      final double keyboardViewportChangeAfterPanel =
          viewportBeforePanel - scrollController.position.viewportDimension;

      expect(
        scrollController.position.pixels - pixelsBeforePanel,
        closeTo(keyboardViewportChangeAfterPanel, 0.01),
        reason:
            'Switching from the attachment panel to the keyboard must keep '
            'the same visible message viewport.',
      );

      tester.view.viewInsets = const FakeViewPadding();
      await tester.pumpAndSettle();

      expect(
        scrollController.position.pixels,
        closeTo(pixelsBeforePanel, 0.01),
        reason:
            'Closing the keyboard after an attachment-panel transition must '
            'restore the same message viewport without cumulative drift.',
      );
    },
  );

  testWidgets('a taller keyboard keeps the latest message above the composer', (
    WidgetTester tester,
  ) async {
    final ChatRealtimeService realtimeService = await _pumpConversationHome(
      tester,
      conversationResponder: (http.Request request) async {
        return http.Response(
          jsonEncode(
            List<Map<String, dynamic>>.generate(
              100,
              (int offset) => _messageJson(offset + 300),
            ),
          ),
          200,
          headers: const <String, String>{
            'content-type': 'application/json',
            'x-has-more': 'true',
          },
        );
      },
    );
    addTearDown(realtimeService.dispose);
    addTearDown(tester.view.resetViewInsets);

    await tester.tap(find.text(_otherUser.displayName));
    await tester.pumpAndSettle();

    final Finder latestBubbleFinder = find.byKey(
      const ValueKey<String>('incoming-bubble-message-399'),
    );
    final Finder composerFinder = find.byKey(
      const ValueKey<String>('message-composer-default'),
    );
    final Finder inputFinder = find.byKey(
      const ValueKey<String>('message-input'),
    );

    await tester.tap(inputFinder);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();

    expect(
      tester.getRect(composerFinder).top -
          tester.getRect(latestBubbleFinder).bottom,
      closeTo(12, 1),
    );

    tester.view.viewInsets = const FakeViewPadding(bottom: 380);
    await tester.pumpAndSettle();

    expect(latestBubbleFinder, findsOneWidget);
    expect(
      tester.getRect(composerFinder).top -
          tester.getRect(latestBubbleFinder).bottom,
      closeTo(12, 1),
      reason:
          'Switching to the taller emoji keyboard must move the message '
          'viewport with the composer.',
    );

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();

    expect(
      tester.getRect(composerFinder).top -
          tester.getRect(latestBubbleFinder).bottom,
      closeTo(12, 1),
      reason:
          'Switching back to the shorter text keyboard must keep the latest '
          'message anchored above the composer.',
    );
  });

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

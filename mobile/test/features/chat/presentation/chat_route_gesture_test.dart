import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juliatalk/core/notifications/notification_service.dart';
import 'package:juliatalk/features/auth/domain/app_user.dart';
import 'package:juliatalk/features/auth/domain/auth_session.dart';
import 'package:juliatalk/features/chat/data/chat_api.dart';
import 'package:juliatalk/features/chat/data/chat_realtime_service.dart';
import 'package:juliatalk/features/chat/presentation/chat_conversation_screen.dart';

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

ListView _messageList(WidgetTester tester) {
  return tester.widget<ListView>(
    find.byKey(const ValueKey<String>('message-list')),
  );
}

Future<ChatRealtimeService> _pumpOpenConversation(WidgetTester tester) async {
  final MockClient client = MockClient((http.Request request) async {
    if (request.method == 'GET' && request.url.path == '/users') {
      return http.Response(
        jsonEncode(<Map<String, dynamic>>[_otherUser.toJson()]),
        200,
        headers: const <String, String>{'content-type': 'application/json'},
      );
    }

    if (request.method == 'GET' &&
        request.url.path == '/messages/conversation/${_otherUser.id}') {
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
      ),
    ),
  );
  await tester.pumpAndSettle();
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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/features/chat/domain/chat_message.dart';
import 'package:juliatalk/features/chat/presentation/chat_conversation_view.dart';

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
  testWidgets('target-language incoming text does not request translation', (
    WidgetTester tester,
  ) async {
    int translationRequests = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: ChatConversationView(
          initialMessages: <ChatMessage>[
            ChatMessage(
              id: 'target-language',
              senderId: '2',
              recipientId: '1',
              content: '앞으로 너에게도 내 진심을 자주 말해 줄게',
              createdAt: DateTime(2026, 7, 10, 19, 21),
              sourceLanguage: 'zh-CN',
              translatedLanguage: 'ko',
            ),
          ],
          currentUserPreferredLanguage: 'ko',
          onTranslateMessage: (ChatMessage message) async {
            translationRequests++;
            return 'translated';
          },
        ),
      ),
    );

    await tester.pumpAndSettle();

    await tester.tap(find.text('앞으로 너에게도 내 진심을 자주 말해 줄게'));
    await tester.pumpAndSettle();

    expect(translationRequests, 0);
    expect(find.text('번역 중...'), findsNothing);
  });

  testWidgets('target-language failed translation status is hidden', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ChatConversationView(
          initialMessages: <ChatMessage>[
            ChatMessage(
              id: 'target-language-failed',
              senderId: '2',
              recipientId: '1',
              content: '너는나를존중해야한다나는발롱도르5개와수많은개인트로피를들어올렸으며',
              createdAt: DateTime(2026, 7, 10, 19, 21),
              translationStatus: ChatTranslationStatus.failed,
              translationFailureReason: 'Server translation failed',
              sourceLanguage: 'zh-CN',
              translatedLanguage: 'ko',
            ),
          ],
          currentUserPreferredLanguage: 'ko',
          onTranslateMessage: (ChatMessage message) async {
            return 'translated';
          },
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.textContaining('너는나를존중해야한다'), findsOneWidget);
    expect(find.text('지금은 이 메시지를 번역할 수 없어요.'), findsNothing);
    expect(find.text('다시 해보기'), findsNothing);
  });

  testWidgets('failed translation status uses Chinese user labels', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ChatConversationView(
          initialMessages: <ChatMessage>[
            ChatMessage(
              id: 'chinese-user-failed',
              senderId: '2',
              recipientId: '1',
              content: '자기야 사랑해',
              createdAt: DateTime(2026, 7, 10, 19, 21),
              translationStatus: ChatTranslationStatus.failed,
              translationFailureReason: 'Server translation failed',
              sourceLanguage: 'ko',
              translatedLanguage: 'zh-CN',
            ),
          ],
          currentUserPreferredLanguage: 'zh-CN',
          onTranslateMessage: (ChatMessage message) async {
            return 'translated';
          },
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('暂时无法翻译这条消息。'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.textContaining('Translation failed:'), findsNothing);
  });

  testWidgets('translating status uses Chinese user label', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ChatConversationView(
          initialMessages: <ChatMessage>[
            ChatMessage(
              id: 'chinese-user-translating',
              senderId: '2',
              recipientId: '1',
              content: '자기야 사랑해',
              createdAt: DateTime(2026, 7, 10, 19, 21),
              translationStatus: ChatTranslationStatus.translating,
              sourceLanguage: 'ko',
              translatedLanguage: 'zh-CN',
            ),
          ],
          currentUserPreferredLanguage: 'zh-CN',
          onTranslateMessage: (ChatMessage message) async {
            return 'translated';
          },
        ),
      ),
    );

    await tester.pump();

    expect(find.text('正在翻译...'), findsOneWidget);
    expect(find.text('Translating...'), findsNothing);
    expect(find.text('번역 중...'), findsNothing);
  });

  testWidgets('failed translation status keeps text bubble tightly sized', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    const String content = '欧巴我快要登机了但是我还想再跟你说很多很多话';

    await tester.pumpWidget(
      MaterialApp(
        home: ChatConversationView(
          initialMessages: <ChatMessage>[
            ChatMessage(
              id: 'normal-width',
              senderId: '2',
              recipientId: '1',
              content: content,
              createdAt: DateTime(2026, 7, 10, 19, 21),
              sourceLanguage: 'zh-CN',
              translatedLanguage: 'ko',
            ),
            ChatMessage(
              id: 'failed-width',
              senderId: '2',
              recipientId: '1',
              content: content,
              createdAt: DateTime(2026, 7, 10, 19, 22),
              translationStatus: ChatTranslationStatus.failed,
              translationFailureReason: 'Server translation failed',
              sourceLanguage: 'zh-CN',
              translatedLanguage: 'ko',
            ),
          ],
          currentUserPreferredLanguage: 'ko',
          onTranslateMessage: (ChatMessage message) async {
            return 'translated';
          },
        ),
      ),
    );

    await tester.pumpAndSettle();

    final double normalWidth = tester
        .getSize(
          find.byKey(const ValueKey<String>('incoming-bubble-normal-width')),
        )
        .width;
    final double failedWidth = tester
        .getSize(
          find.byKey(const ValueKey<String>('incoming-bubble-failed-width')),
        )
        .width;

    expect(find.text('지금은 이 메시지를 번역할 수 없어요.'), findsOneWidget);
    expect(failedWidth, greaterThanOrEqualTo(normalWidth));
    expect(failedWidth, lessThan(normalWidth + 8));
  });

  testWidgets('failed translation status can size bubble by failure text', (
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
              id: 'short-normal-width',
              senderId: '2',
              recipientId: '1',
              content: '爱你',
              createdAt: DateTime(2026, 7, 10, 19, 21),
              sourceLanguage: 'zh-CN',
              translatedLanguage: 'ko',
            ),
            ChatMessage(
              id: 'short-failed-width',
              senderId: '2',
              recipientId: '1',
              content: '爱你',
              createdAt: DateTime(2026, 7, 10, 19, 22),
              translationStatus: ChatTranslationStatus.failed,
              translationFailureReason: 'Server translation failed',
              sourceLanguage: 'zh-CN',
              translatedLanguage: 'ko',
            ),
          ],
          currentUserPreferredLanguage: 'ko',
          onTranslateMessage: (ChatMessage message) async {
            return 'translated';
          },
        ),
      ),
    );

    await tester.pumpAndSettle();

    final double normalWidth = tester
        .getSize(
          find.byKey(
            const ValueKey<String>('incoming-bubble-short-normal-width'),
          ),
        )
        .width;
    final double failedWidth = tester
        .getSize(
          find.byKey(
            const ValueKey<String>('incoming-bubble-short-failed-width'),
          ),
        )
        .width;

    expect(find.text('지금은 이 메시지를 번역할 수 없어요.'), findsOneWidget);
    expect(failedWidth, greaterThan(normalWidth + 40));
  });

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

    expect(find.text('번역 중...'), findsOneWidget);

    expect(find.text('欧巴我快要登机了'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));

    expect(find.text('번역 중...'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));

    await tester.pumpAndSettle();

    expect(find.text('번역 중...'), findsNothing);

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

      expect(find.text('지금은 이 메시지를 번역할 수 없어요.'), findsOneWidget);

      expect(find.text('다시 해보기'), findsOneWidget);

      await tester.tap(find.text('다시 해보기'));

      await tester.pump();

      expect(find.text('번역 중...'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('지금은 이 메시지를 번역할 수 없어요.'), findsNothing);

      await tester.pump(const Duration(seconds: 4));

      expect(find.text('번역 중...'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));

      await tester.pumpAndSettle();

      expect(find.text('번역 중...'), findsNothing);

      expect(find.text('다음에는 제대로 말할게.'), findsOneWidget);
    },
  );

  testWidgets('failed translation retry uses server retry callback', (
    WidgetTester tester,
  ) async {
    int serverRetryRequests = 0;
    int localTranslationRequests = 0;
    final Completer<ChatMessage> retryCompleter = Completer<ChatMessage>();

    await tester.pumpWidget(
      MaterialApp(
        home: ChatConversationView(
          initialMessages: <ChatMessage>[
            ChatMessage(
              id: 'server-retry',
              senderId: '2',
              recipientId: '1',
              content: '欧巴我快要登机了但是我还想再跟你说很多很多话',
              createdAt: DateTime(2026, 7, 10, 19, 21),
              translationStatus: ChatTranslationStatus.failed,
              translationFailureReason: 'Server translation failed',
              sourceLanguage: 'zh-CN',
              translatedLanguage: 'ko',
            ),
          ],
          currentUserPreferredLanguage: 'ko',
          onTranslateMessage: (ChatMessage message) async {
            localTranslationRequests++;
            return 'local translation';
          },
          onRetryTranslation: ({required String messageId}) async {
            serverRetryRequests++;
            return retryCompleter.future;
          },
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('다시 해보기'), findsOneWidget);

    await tester.tap(find.text('다시 해보기'));
    await tester.pump();

    expect(serverRetryRequests, 1);
    expect(localTranslationRequests, 0);
    expect(find.text('번역 중...'), findsOneWidget);

    retryCompleter.complete(
      ChatMessage(
        id: 'server-retry',
        senderId: '2',
        recipientId: '1',
        content: '欧巴我快要登机了但是我还想再跟你说很多很多话',
        createdAt: DateTime(2026, 7, 10, 19, 21),
        translationStatus: ChatTranslationStatus.translated,
        translatedContent: '오빠, 나 곧 탑승하는데 아직 하고 싶은 말이 많아.',
        sourceLanguage: 'zh-CN',
        translatedLanguage: 'ko',
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('지금은 이 메시지를 번역할 수 없어요.'), findsNothing);
    expect(find.text('다시 해보기'), findsNothing);
    expect(find.text('오빠, 나 곧 탑승하는데 아직 하고 싶은 말이 많아.'), findsOneWidget);
  });

  testWidgets('failed translation retry keeps bottom message visible', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    final Completer<ChatMessage> retryCompleter = Completer<ChatMessage>();
    final DateTime baseTime = DateTime(2026, 7, 10, 19);

    await tester.pumpWidget(
      MaterialApp(
        home: ChatConversationView(
          initialMessages: <ChatMessage>[
            for (int index = 0; index < 10; index++)
              ChatMessage(
                id: 'filler-$index',
                senderId: index.isEven ? '1' : '2',
                recipientId: index.isEven ? '2' : '1',
                content: 'scroll filler message $index',
                createdAt: baseTime.add(Duration(minutes: index)),
              ),
            ChatMessage(
              id: 'retry-bottom-anchor',
              senderId: '2',
              recipientId: '1',
              content: '你好',
              createdAt: baseTime.add(const Duration(minutes: 10)),
              translationStatus: ChatTranslationStatus.failed,
              translationFailureReason: 'Server translation failed',
              sourceLanguage: 'zh-CN',
              translatedLanguage: 'ko',
            ),
            ChatMessage(
              id: 'last-visible-message',
              senderId: '1',
              recipientId: '2',
              content: '안녕',
              createdAt: baseTime.add(const Duration(minutes: 11)),
            ),
          ],
          currentUserPreferredLanguage: 'ko',
          onRetryTranslation: ({required String messageId}) {
            expect(messageId, 'retry-bottom-anchor');
            return retryCompleter.future;
          },
        ),
      ),
    );

    await tester.pumpAndSettle();

    final Finder lastBubbleFinder = find.byKey(
      const ValueKey<String>('outgoing-bubble-last-visible-message'),
    );
    final Finder composerFinder = find.byKey(
      const ValueKey<String>('message-composer-default'),
    );

    expect(lastBubbleFinder, findsOneWidget);

    await tester.tap(find.text('다시 해보기'));
    await tester.pump();

    retryCompleter.completeError(Exception('retry failed'));

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    final Rect lastBubbleRect = tester.getRect(lastBubbleFinder);
    final Rect composerRect = tester.getRect(composerFinder);

    expect(lastBubbleRect.bottom, lessThanOrEqualTo(composerRect.top));
  });

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

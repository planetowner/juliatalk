import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juliatalk/features/chat/data/chat_api.dart';
import 'package:juliatalk/features/chat/data/chat_message_cache.dart';
import 'package:juliatalk/features/chat/domain/chat_message.dart';

void main() {
  late Directory cacheDirectory;
  late ChatApi chatApi;

  setUp(() async {
    cacheDirectory = await Directory.systemTemp.createTemp(
      'juliatalk-message-cache-test-',
    );
    chatApi = ChatApi(
      client: MockClient((http.Request request) async {
        throw StateError('The cache test must not make a network request.');
      }),
      baseUri: Uri.parse('https://api.example.com'),
      accessToken: 'test-token',
    );
  });

  tearDown(() async {
    if (await cacheDirectory.exists()) {
      await cacheDirectory.delete(recursive: true);
    }
  });

  ChatMessage message({
    required String id,
    required int minute,
    ChatReplyReference? replyTo,
  }) {
    return ChatMessage(
      id: id,
      senderId: '11111111-1111-4111-8111-111111111111',
      recipientId: '22222222-2222-4222-8222-222222222222',
      content: 'message-$minute',
      createdAt: DateTime.utc(2026, 7, 29, 12, minute),
      translationStatus: ChatTranslationStatus.translated,
      translatedContent: 'translated-$minute',
      sourceLanguage: 'ko',
      translatedLanguage: 'en',
      replyTo: replyTo,
    );
  }

  ChatMessageCache createCache() {
    return ChatMessageCache(
      chatApi: chatApi,
      currentUserId: '11111111-1111-4111-8111-111111111111',
      directoryLoader: () async => cacheDirectory,
    );
  }

  test('persists a contiguous range and reads a small target window', () async {
    final ChatMessage first = message(
      id: '33333333-3333-4333-8333-333333333301',
      minute: 1,
    );
    final ChatMessage second = message(
      id: '33333333-3333-4333-8333-333333333302',
      minute: 2,
      replyTo: ChatReplyReference(
        messageId: first.id,
        senderId: first.senderId,
        content: first.content,
      ),
    );
    final ChatMessage third = message(
      id: '33333333-3333-4333-8333-333333333303',
      minute: 3,
    );
    final ChatMessageCache cache = createCache();

    await cache.mergeLatestConversation(
      otherUserId: '22222222-2222-4222-8222-222222222222',
      messages: <ChatMessage>[second, third],
      hasMoreOlder: true,
    );
    await cache.mergeOlderPage(
      otherUserId: '22222222-2222-4222-8222-222222222222',
      beforeMessageId: second.id,
      messages: <ChatMessage>[first],
      hasMoreOlder: false,
    );

    final ChatMessageCache reloadedCache = createCache();
    final ChatCachedConversation fullConversation = await reloadedCache
        .readConversation('22222222-2222-4222-8222-222222222222');
    final ChatCachedConversation? context = await reloadedCache
        .readConversationAround(
          otherUserId: '22222222-2222-4222-8222-222222222222',
          messageId: second.id,
          olderLimit: 1,
          newerLimit: 1,
        );
    final ChatCachedConversation? olderPage = await reloadedCache
        .readMessagesBefore(
          otherUserId: '22222222-2222-4222-8222-222222222222',
          beforeMessageId: third.id,
          limit: 1,
        );

    expect(
      fullConversation.messages.map((ChatMessage item) => item.id),
      <String>[first.id, second.id, third.id],
    );
    expect(fullConversation.hasMoreOlder, isFalse);
    expect(context?.messages.map((ChatMessage item) => item.id), <String>[
      first.id,
      second.id,
      third.id,
    ]);
    expect(context?.hasMoreOlder, isFalse);
    expect(context?.hasMoreNewer, isFalse);
    expect(context?.messages[1].replyTo?.messageId, first.id);
    expect(context?.messages[1].translatedContent, 'translated-2');
    expect(olderPage?.messages.map((ChatMessage item) => item.id), <String>[
      second.id,
    ]);
    expect(olderPage?.hasMoreOlder, isTrue);
  });

  test(
    'a latest-only refresh does not forget a completed older archive',
    () async {
      final ChatMessage first = message(
        id: '33333333-3333-4333-8333-333333333311',
        minute: 1,
      );
      final ChatMessage latest = message(
        id: '33333333-3333-4333-8333-333333333312',
        minute: 2,
      );
      final ChatMessageCache cache = createCache();

      await cache.mergeConversationContext(
        otherUserId: '22222222-2222-4222-8222-222222222222',
        messages: <ChatMessage>[first, latest],
        hasMoreOlder: false,
        hasMoreNewer: false,
      );
      await cache.mergeLatestConversation(
        otherUserId: '22222222-2222-4222-8222-222222222222',
        messages: <ChatMessage>[latest],
        hasMoreOlder: true,
      );

      final ChatMessageCache reloadedCache = createCache();
      final ChatCachedConversation conversation = await reloadedCache
          .readConversation('22222222-2222-4222-8222-222222222222');

      expect(conversation.hasMoreOlder, isFalse);
      expect(conversation.messages.map((ChatMessage item) => item.id), <String>[
        first.id,
        latest.id,
      ]);
    },
  );

  test('keeps non-overlapping context and latest ranges separate', () async {
    final ChatMessage oldMessage = message(
      id: '33333333-3333-4333-8333-333333333321',
      minute: 1,
    );
    final ChatMessage newMessage = message(
      id: '33333333-3333-4333-8333-333333333322',
      minute: 20,
    );
    final ChatMessageCache cache = createCache();

    await cache.mergeConversationContext(
      otherUserId: '22222222-2222-4222-8222-222222222222',
      messages: <ChatMessage>[oldMessage],
      hasMoreOlder: false,
      hasMoreNewer: true,
    );
    await cache.mergeLatestConversation(
      otherUserId: '22222222-2222-4222-8222-222222222222',
      messages: <ChatMessage>[newMessage],
      hasMoreOlder: true,
    );

    final ChatMessageCache reloadedCache = createCache();
    final ChatCachedConversation conversation = await reloadedCache
        .readConversation('22222222-2222-4222-8222-222222222222');

    expect(conversation.messages.map((ChatMessage item) => item.id), <String>[
      newMessage.id,
    ]);
    expect(conversation.hasMoreOlder, isTrue);
    final ChatCachedConversation? oldContext = await reloadedCache
        .readConversationAround(
          otherUserId: '22222222-2222-4222-8222-222222222222',
          messageId: oldMessage.id,
          olderLimit: 10,
          newerLimit: 10,
        );
    expect(oldContext?.messages.map((ChatMessage item) => item.id), <String>[
      oldMessage.id,
    ]);
    expect(oldContext?.hasMoreNewer, isTrue);
  });

  test('an explicitly connected older page extends the archive', () async {
    final ChatMessage older = message(
      id: '33333333-3333-4333-8333-333333333331',
      minute: 1,
    );
    final ChatMessage latest = message(
      id: '33333333-3333-4333-8333-333333333332',
      minute: 2,
    );
    final ChatMessageCache cache = createCache();

    await cache.mergeLatestConversation(
      otherUserId: '22222222-2222-4222-8222-222222222222',
      messages: <ChatMessage>[latest],
      hasMoreOlder: true,
    );
    await cache.mergeOlderPage(
      otherUserId: '22222222-2222-4222-8222-222222222222',
      beforeMessageId: latest.id,
      messages: <ChatMessage>[older],
      hasMoreOlder: false,
    );

    final ChatCachedConversation conversation = await cache.readConversation(
      '22222222-2222-4222-8222-222222222222',
    );

    expect(conversation.messages.map((ChatMessage item) => item.id), <String>[
      older.id,
      latest.id,
    ]);
    expect(conversation.hasMoreOlder, isFalse);
  });

  test('reads cached messages after a context cursor', () async {
    final ChatMessage first = message(
      id: '33333333-3333-4333-8333-333333333341',
      minute: 1,
    );
    final ChatMessage second = message(
      id: '33333333-3333-4333-8333-333333333342',
      minute: 2,
    );
    final ChatMessage third = message(
      id: '33333333-3333-4333-8333-333333333343',
      minute: 3,
    );
    final ChatMessageCache cache = createCache();

    await cache.mergeConversationContext(
      otherUserId: '22222222-2222-4222-8222-222222222222',
      messages: <ChatMessage>[first, second, third],
      hasMoreOlder: true,
      hasMoreNewer: true,
    );

    final ChatCachedConversation? newerPage = await cache.readMessagesAfter(
      otherUserId: '22222222-2222-4222-8222-222222222222',
      afterMessageId: first.id,
      limit: 1,
    );

    expect(newerPage?.messages.map((ChatMessage item) => item.id), <String>[
      second.id,
    ]);
    expect(newerPage?.hasMoreNewer, isTrue);
  });

  test('persists video attachment metadata', () async {
    final ChatMessage videoMessage = ChatMessage(
      id: '33333333-3333-4333-8333-333333333350',
      senderId: '11111111-1111-4111-8111-111111111111',
      recipientId: '22222222-2222-4222-8222-222222222222',
      content: '',
      createdAt: DateTime.utc(2026, 8, 17, 6, 30),
      videoAttachment: const ChatVideoAttachment(
        assetId: '44444444-4444-4444-8444-444444444444',
        mediaAssetId: '44444444-4444-4444-8444-444444444444',
        width: 1080,
        height: 1920,
        duration: Duration(seconds: 14),
        fileName: 'video.mov',
        mimeType: 'video/quicktime',
        sizeBytes: 1820000,
      ),
    );
    final ChatMessageCache cache = createCache();

    await cache.mergeLatestConversation(
      otherUserId: '22222222-2222-4222-8222-222222222222',
      messages: <ChatMessage>[videoMessage],
      hasMoreOlder: false,
    );

    final ChatCachedConversation conversation = await createCache()
        .readConversation('22222222-2222-4222-8222-222222222222');
    final ChatVideoAttachment? video =
        conversation.messages.single.videoAttachment;

    expect(video?.mediaAssetId, '44444444-4444-4444-8444-444444444444');
    expect(video?.width, 1080);
    expect(video?.height, 1920);
    expect(video?.duration, const Duration(seconds: 14));
    expect(video?.fileName, 'video.mov');
    expect(video?.mimeType, 'video/quicktime');
    expect(video?.sizeBytes, 1820000);
  });
}

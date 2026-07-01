import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/features/chat/domain/chat_message_action.dart';

void main() {
  group('availableChatMessageActions', () {
    final DateTime createdAt = DateTime(2026, 6, 30, 20, 30);

    test('incoming messages only allow copy and reply', () {
      final List<ChatMessageAction> actions = availableChatMessageActions(
        isOutgoing: false,
        createdAt: createdAt,
        now: createdAt,
      );

      expect(actions, const <ChatMessageAction>[
        ChatMessageAction.copy,
        ChatMessageAction.reply,
      ]);
    });

    test('outgoing messages within five minutes allow unsend', () {
      final List<ChatMessageAction> actions = availableChatMessageActions(
        isOutgoing: true,
        createdAt: createdAt,
        now: createdAt.add(const Duration(minutes: 4, seconds: 59)),
      );

      expect(actions, const <ChatMessageAction>[
        ChatMessageAction.copy,
        ChatMessageAction.reply,
        ChatMessageAction.edit,
        ChatMessageAction.unsend,
      ]);
    });

    test('outgoing messages allow unsend at exactly five minutes', () {
      final List<ChatMessageAction> actions = availableChatMessageActions(
        isOutgoing: true,
        createdAt: createdAt,
        now: createdAt.add(const Duration(minutes: 5)),
      );

      expect(actions, contains(ChatMessageAction.unsend));
    });

    test('outgoing messages older than five minutes omit unsend', () {
      final List<ChatMessageAction> actions = availableChatMessageActions(
        isOutgoing: true,
        createdAt: createdAt,
        now: createdAt.add(const Duration(minutes: 5, milliseconds: 1)),
      );

      expect(actions, const <ChatMessageAction>[
        ChatMessageAction.copy,
        ChatMessageAction.reply,
        ChatMessageAction.edit,
      ]);
    });

    test(
      'outgoing photo messages allow reply and unsend but not copy or edit',
      () {
        final List<ChatMessageAction> actions = availableChatMessageActions(
          isOutgoing: true,
          createdAt: createdAt,
          now: createdAt,
          isMedia: true,
        );

        expect(actions, const <ChatMessageAction>[
          ChatMessageAction.reply,
          ChatMessageAction.unsend,
        ]);
      },
    );
  });
}

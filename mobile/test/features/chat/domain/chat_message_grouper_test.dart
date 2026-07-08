import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/features/chat/domain/chat_message.dart';
import 'package:juliatalk/features/chat/domain/chat_message_grouper.dart';

void main() {
  test('groups consecutive messages from the same sender and minute', () {
    final messages = [
      ChatMessage(
        id: '1',
        senderId: '2',
        recipientId: '1',
        content: 'First',
        createdAt: DateTime(2026, 6, 30, 8, 30, 5),
      ),
      ChatMessage(
        id: '2',
        senderId: '2',
        recipientId: '1',
        content: 'Second',
        createdAt: DateTime(2026, 6, 30, 8, 30, 50),
      ),
    ];

    final groups = groupChatMessages(messages);

    expect(groups, hasLength(1));

    expect(groups.single.messages.map((message) => message.id).toList(), [
      '1',
      '2',
    ]);
  });

  test('does not group messages separated by another sender', () {
    final messages = [
      ChatMessage(
        id: '1',
        senderId: '2',
        recipientId: '1',
        content: 'First',
        createdAt: DateTime(2026, 6, 30, 8, 30, 5),
      ),
      ChatMessage(
        id: '2',
        senderId: '1',
        recipientId: '2',
        content: 'Reply',
        createdAt: DateTime(2026, 6, 30, 8, 30, 20),
      ),
      ChatMessage(
        id: '3',
        senderId: '2',
        recipientId: '1',
        content: 'Third',
        createdAt: DateTime(2026, 6, 30, 8, 30, 40),
      ),
    ];

    final groups = groupChatMessages(messages);

    expect(groups, hasLength(3));
    expect(groups[0].messages.single.id, '1');
    expect(groups[1].messages.single.id, '2');
    expect(groups[2].messages.single.id, '3');
  });

  test('does not group messages from different minutes', () {
    final messages = [
      ChatMessage(
        id: '1',
        senderId: '2',
        recipientId: '1',
        content: 'First',
        createdAt: DateTime(2026, 6, 30, 8, 30, 59),
      ),
      ChatMessage(
        id: '2',
        senderId: '2',
        recipientId: '1',
        content: 'Second',
        createdAt: DateTime(2026, 6, 30, 8, 31),
      ),
    ];

    final groups = groupChatMessages(messages);

    expect(groups, hasLength(2));
  });

  test('sorts messages before grouping them', () {
    final messages = [
      ChatMessage(
        id: '2',
        senderId: '2',
        recipientId: '1',
        content: 'Second',
        createdAt: DateTime(2026, 6, 30, 8, 30, 40),
      ),
      ChatMessage(
        id: '1',
        senderId: '2',
        recipientId: '1',
        content: 'First',
        createdAt: DateTime(2026, 6, 30, 8, 30, 5),
      ),
    ];

    final groups = groupChatMessages(messages);

    expect(groups.single.messages.map((message) => message.id).toList(), [
      '1',
      '2',
    ]);
  });

  test('finds the latest read outgoing message', () {
    final messages = [
      ChatMessage(
        id: '1',
        senderId: '1',
        recipientId: '2',
        content: 'Read first',
        createdAt: DateTime(2026, 6, 30, 8, 30),
        readAt: DateTime(2026, 6, 30, 8, 31),
      ),
      ChatMessage(
        id: '2',
        senderId: '1',
        recipientId: '2',
        content: 'Read second',
        createdAt: DateTime(2026, 6, 30, 8, 32),
        readAt: DateTime(2026, 6, 30, 8, 33),
      ),
      ChatMessage(
        id: '3',
        senderId: '1',
        recipientId: '2',
        content: 'Unread',
        createdAt: DateTime(2026, 6, 30, 8, 34),
      ),
    ];

    expect(
      findLatestReadOutgoingMessageId(messages: messages, currentUserId: '1'),
      '2',
    );
  });
}

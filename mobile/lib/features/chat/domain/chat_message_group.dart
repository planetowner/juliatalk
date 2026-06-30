import 'chat_message.dart';

final class ChatMessageGroup {
  ChatMessageGroup({
    required this.senderId,
    required List<ChatMessage> messages,
  }) : messages = List<ChatMessage>.unmodifiable(messages);

  final int senderId;
  final List<ChatMessage> messages;

  DateTime get createdAt {
    return messages.first.createdAt;
  }
}

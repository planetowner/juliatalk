import 'chat_message.dart';
import 'chat_message_group.dart';

List<ChatMessageGroup> groupChatMessages(List<ChatMessage> messages) {
  if (messages.isEmpty) {
    return const <ChatMessageGroup>[];
  }

  final List<ChatMessage> sortedMessages = List<ChatMessage>.of(messages)
    ..sort(_compareMessages);

  final List<ChatMessageGroup> groups = [];

  int currentSenderId = sortedMessages.first.senderId;
  List<ChatMessage> currentMessages = [sortedMessages.first];

  for (final ChatMessage message in sortedMessages.skip(1)) {
    final ChatMessage previousMessage = currentMessages.last;

    final bool continuesCurrentGroup =
        message.senderId == currentSenderId &&
        isSameChatMinute(previousMessage.createdAt, message.createdAt);

    if (continuesCurrentGroup) {
      currentMessages.add(message);
      continue;
    }

    groups.add(
      ChatMessageGroup(senderId: currentSenderId, messages: currentMessages),
    );

    currentSenderId = message.senderId;
    currentMessages = [message];
  }

  groups.add(
    ChatMessageGroup(senderId: currentSenderId, messages: currentMessages),
  );

  return List<ChatMessageGroup>.unmodifiable(groups);
}

int? findLatestReadOutgoingMessageId({
  required List<ChatMessage> messages,
  required int currentUserId,
}) {
  ChatMessage? latestReadMessage;

  for (final ChatMessage message in messages) {
    if (message.senderId != currentUserId || message.readAt == null) {
      continue;
    }

    final ChatMessage? currentLatest = latestReadMessage;

    if (currentLatest == null || _compareMessages(currentLatest, message) < 0) {
      latestReadMessage = message;
    }
  }

  return latestReadMessage?.id;
}

bool isSameChatMinute(DateTime first, DateTime second) {
  final DateTime localFirst = first.toLocal();
  final DateTime localSecond = second.toLocal();

  return localFirst.year == localSecond.year &&
      localFirst.month == localSecond.month &&
      localFirst.day == localSecond.day &&
      localFirst.hour == localSecond.hour &&
      localFirst.minute == localSecond.minute;
}

bool isSameChatDate(DateTime first, DateTime second) {
  final DateTime localFirst = first.toLocal();
  final DateTime localSecond = second.toLocal();

  return localFirst.year == localSecond.year &&
      localFirst.month == localSecond.month &&
      localFirst.day == localSecond.day;
}

int _compareMessages(ChatMessage first, ChatMessage second) {
  final int dateComparison = first.createdAt.compareTo(second.createdAt);

  if (dateComparison != 0) {
    return dateComparison;
  }

  return first.id.compareTo(second.id);
}

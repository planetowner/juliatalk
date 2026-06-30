enum ChatTranslationStatus { none, translating, translated, failed }

final class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.recipientId,
    required this.content,
    required this.createdAt,
    this.readAt,
    this.translationStatus = ChatTranslationStatus.none,
    this.translatedContent,
    this.translationFailureReason,
  });

  final int id;
  final int senderId;
  final int recipientId;
  final String content;
  final DateTime createdAt;
  final DateTime? readAt;

  final ChatTranslationStatus translationStatus;
  final String? translatedContent;
  final String? translationFailureReason;

  ChatMessage copyWith({
    ChatTranslationStatus? translationStatus,
    String? translatedContent,
    String? translationFailureReason,
    bool clearTranslatedContent = false,
    bool clearTranslationFailureReason = false,
  }) {
    return ChatMessage(
      id: id,
      senderId: senderId,
      recipientId: recipientId,
      content: content,
      createdAt: createdAt,
      readAt: readAt,
      translationStatus: translationStatus ?? this.translationStatus,
      translatedContent: clearTranslatedContent
          ? null
          : translatedContent ?? this.translatedContent,
      translationFailureReason: clearTranslationFailureReason
          ? null
          : translationFailureReason ?? this.translationFailureReason,
    );
  }
}

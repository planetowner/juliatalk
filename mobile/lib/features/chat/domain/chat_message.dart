import 'dart:typed_data';

enum ChatTranslationStatus { none, translating, translated, failed }

final class ChatReplyReference {
  const ChatReplyReference({
    required this.messageId,
    required this.senderId,
    required this.content,
  });

  final int messageId;
  final int senderId;
  final String content;
}

final class ChatPhotoAttachment {
  const ChatPhotoAttachment({
    required this.assetId,
    required this.previewBytes,
    required this.width,
    required this.height,
  });

  final String assetId;
  final Uint8List previewBytes;
  final int width;
  final int height;
}

final class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.recipientId,
    required this.content,
    required this.createdAt,
    this.readAt,
    this.editedAt,
    this.translationStatus = ChatTranslationStatus.none,
    this.translatedContent,
    this.translationFailureReason,
    this.replyTo,
    this.photoAttachments = const <ChatPhotoAttachment>[],
  });

  final int id;
  final int senderId;
  final int recipientId;
  final String content;
  final DateTime createdAt;
  final DateTime? readAt;
  final DateTime? editedAt;

  final ChatTranslationStatus translationStatus;
  final String? translatedContent;
  final String? translationFailureReason;
  final ChatReplyReference? replyTo;
  final List<ChatPhotoAttachment> photoAttachments;

  bool get isPhotoMessage {
    return photoAttachments.isNotEmpty;
  }

  String get replyPreviewContent {
    if (!isPhotoMessage) {
      return content;
    }

    if (photoAttachments.length == 1) {
      return 'Photo';
    }

    return '${photoAttachments.length} Photos';
  }

  ChatMessage copyWith({
    String? content,
    DateTime? editedAt,
    ChatTranslationStatus? translationStatus,
    String? translatedContent,
    String? translationFailureReason,
    ChatReplyReference? replyTo,
    List<ChatPhotoAttachment>? photoAttachments,
    bool clearEditedAt = false,
    bool clearTranslatedContent = false,
    bool clearTranslationFailureReason = false,
    bool clearReplyTo = false,
    bool clearPhotoAttachments = false,
  }) {
    return ChatMessage(
      id: id,
      senderId: senderId,
      recipientId: recipientId,
      content: content ?? this.content,
      createdAt: createdAt,
      readAt: readAt,
      editedAt: clearEditedAt ? null : editedAt ?? this.editedAt,
      translationStatus: translationStatus ?? this.translationStatus,
      translatedContent: clearTranslatedContent
          ? null
          : translatedContent ?? this.translatedContent,
      translationFailureReason: clearTranslationFailureReason
          ? null
          : translationFailureReason ?? this.translationFailureReason,
      replyTo: clearReplyTo ? null : replyTo ?? this.replyTo,
      photoAttachments: clearPhotoAttachments
          ? const <ChatPhotoAttachment>[]
          : photoAttachments ?? this.photoAttachments,
    );
  }
}

import 'dart:typed_data';

enum ChatTranslationStatus { none, translating, translated, failed }

enum ChatCallKind { voice, video }

enum ChatCallOutcome { started, ended, cancelled, missed, noAnswer }

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

final class ChatFileAttachment {
  const ChatFileAttachment({
    required this.name,
    required this.sizeBytes,
  });

  final String name;
  final int sizeBytes;
}

final class ChatCallAttachment {
  const ChatCallAttachment({
    required this.kind,
    required this.outcome,
    required this.duration,
  });

  final ChatCallKind kind;
  final ChatCallOutcome outcome;
  final Duration duration;
}

final class ChatVoiceMemoAttachment {
  const ChatVoiceMemoAttachment({
    required this.duration,
  });

  final Duration duration;
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
    this.fileAttachment,
    this.callAttachment,
    this.voiceMemoAttachment,
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
  final ChatFileAttachment? fileAttachment;
  final ChatCallAttachment? callAttachment;
  final ChatVoiceMemoAttachment? voiceMemoAttachment;

  bool get isPhotoMessage {
    return photoAttachments.isNotEmpty;
  }

  bool get isFileMessage {
    return fileAttachment != null;
  }

  bool get isCallMessage {
    return callAttachment != null;
  }

  bool get isVoiceMemoMessage {
    return voiceMemoAttachment != null;
  }

  String get replyPreviewContent {
    if (isVoiceMemoMessage) {
      return 'Voice Memo';
    }

    if (isCallMessage) {
      return switch (callAttachment!.outcome) {
        ChatCallOutcome.started => 'Voice Call',
        ChatCallOutcome.ended => 'End voice call',
        ChatCallOutcome.cancelled => 'Cancelled',
        ChatCallOutcome.missed => 'Missed Call',
        ChatCallOutcome.noAnswer => 'No Answer',
      };
    }

    if (isFileMessage) {
      return fileAttachment!.name;
    }

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
    DateTime? readAt,
    DateTime? editedAt,
    ChatTranslationStatus? translationStatus,
    String? translatedContent,
    String? translationFailureReason,
    ChatReplyReference? replyTo,
    List<ChatPhotoAttachment>? photoAttachments,
    ChatFileAttachment? fileAttachment,
    ChatCallAttachment? callAttachment,
    ChatVoiceMemoAttachment? voiceMemoAttachment,
    bool clearEditedAt = false,
    bool clearReadAt = false,
    bool clearTranslatedContent = false,
    bool clearTranslationFailureReason = false,
    bool clearReplyTo = false,
    bool clearPhotoAttachments = false,
    bool clearFileAttachment = false,
    bool clearCallAttachment = false,
    bool clearVoiceMemoAttachment = false,
  }) {
    return ChatMessage(
      id: id,
      senderId: senderId,
      recipientId: recipientId,
      content: content ?? this.content,
      createdAt: createdAt,
      readAt: clearReadAt ? null : readAt ?? this.readAt,
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
      fileAttachment: clearFileAttachment
          ? null
          : fileAttachment ?? this.fileAttachment,
      callAttachment: clearCallAttachment
          ? null
          : callAttachment ?? this.callAttachment,
      voiceMemoAttachment: clearVoiceMemoAttachment
          ? null
          : voiceMemoAttachment ?? this.voiceMemoAttachment,
    );
  }
}

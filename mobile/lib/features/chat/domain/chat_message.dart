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

  final String messageId;
  final String senderId;
  final String content;
}

final class ChatPhotoAttachment {
  const ChatPhotoAttachment({
    required this.assetId,
    required this.width,
    required this.height,
    this.mediaAssetId,
    this.previewBytes,
    this.fileName,
    this.mimeType,
    this.sizeBytes,
    this.uploadBytes,
  });

  final String assetId;
  final int width;
  final int height;
  final String? mediaAssetId;
  final Uint8List? previewBytes;
  final String? fileName;
  final String? mimeType;
  final int? sizeBytes;
  final Uint8List? uploadBytes;
}

final class ChatFileAttachment {
  const ChatFileAttachment({
    required this.name,
    required this.sizeBytes,
    this.mediaAssetId,
    this.mimeType,
    this.uploadBytes,
  });

  final String name;
  final int sizeBytes;
  final String? mediaAssetId;
  final String? mimeType;
  final Uint8List? uploadBytes;
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
    this.audioBytes,
    this.mimeType,
    this.fileName,
    this.sizeBytes,
    this.localPath,
    this.mediaAssetId,
    this.waveformSamples = const <double>[],
  });

  final Duration duration;
  final Uint8List? audioBytes;
  final String? mimeType;
  final String? fileName;
  final int? sizeBytes;
  final String? localPath;
  final String? mediaAssetId;
  final List<double> waveformSamples;

  bool get hasPlayableAudio {
    return localPath != null ||
        mediaAssetId != null ||
        (audioBytes != null && audioBytes!.isNotEmpty);
  }
}

final class ChatLinkPreview {
  const ChatLinkPreview({
    required this.url,
    required this.domain,
    this.canonicalUrl,
    this.title,
    this.description,
    this.siteName,
    this.imageUrl,
  });

  final String url;
  final String domain;
  final String? canonicalUrl;
  final String? title;
  final String? description;
  final String? siteName;
  final String? imageUrl;
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
    this.sourceLanguage,
    this.translatedLanguage,
    this.translationFailureReason,
    this.replyTo,
    this.photoAttachments = const <ChatPhotoAttachment>[],
    this.fileAttachment,
    this.callAttachment,
    this.voiceMemoAttachment,
    this.linkPreview,
  });

  final String id;
  final String senderId;
  final String recipientId;
  final String content;
  final DateTime createdAt;
  final DateTime? readAt;
  final DateTime? editedAt;

  final ChatTranslationStatus translationStatus;
  final String? translatedContent;
  final String? sourceLanguage;
  final String? translatedLanguage;
  final String? translationFailureReason;
  final ChatReplyReference? replyTo;
  final List<ChatPhotoAttachment> photoAttachments;
  final ChatFileAttachment? fileAttachment;
  final ChatCallAttachment? callAttachment;
  final ChatVoiceMemoAttachment? voiceMemoAttachment;
  final ChatLinkPreview? linkPreview;

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

  bool get isLinkMessage {
    return linkPreview != null;
  }

  String get replyPreviewContent {
    if (isVoiceMemoMessage) {
      return 'Voice Memo';
    }

    if (isLinkMessage) {
      return linkPreview!.title ?? linkPreview!.domain;
    }

    if (isCallMessage) {
      return switch (callAttachment!.outcome) {
        ChatCallOutcome.started => 'Voice Call',
        ChatCallOutcome.ended => 'End voice call',
        ChatCallOutcome.cancelled => 'Canceled',
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
    String? sourceLanguage,
    String? translatedLanguage,
    String? translationFailureReason,
    ChatReplyReference? replyTo,
    List<ChatPhotoAttachment>? photoAttachments,
    ChatFileAttachment? fileAttachment,
    ChatCallAttachment? callAttachment,
    ChatVoiceMemoAttachment? voiceMemoAttachment,
    ChatLinkPreview? linkPreview,
    bool clearEditedAt = false,
    bool clearReadAt = false,
    bool clearTranslatedContent = false,
    bool clearTranslationFailureReason = false,
    bool clearReplyTo = false,
    bool clearPhotoAttachments = false,
    bool clearFileAttachment = false,
    bool clearCallAttachment = false,
    bool clearVoiceMemoAttachment = false,
    bool clearLinkPreview = false,
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
      sourceLanguage: sourceLanguage ?? this.sourceLanguage,
      translatedLanguage: translatedLanguage ?? this.translatedLanguage,
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
      linkPreview: clearLinkPreview ? null : linkPreview ?? this.linkPreview,
    );
  }
}

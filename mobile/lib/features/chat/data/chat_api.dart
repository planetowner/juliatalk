import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../auth/domain/app_user.dart';
import '../domain/chat_message.dart';
import 'chat_api_exception.dart';

final class ChatApi {
  const ChatApi({
    required http.Client client,
    required Uri baseUri,
    required String accessToken,
  }) : _client = client,
       _baseUri = baseUri,
       _accessToken = accessToken;

  final http.Client _client;
  final Uri _baseUri;
  final String _accessToken;

  Map<String, String> get _headers {
    return <String, String>{
      'Accept': 'application/json',
      'Authorization': 'Bearer $_accessToken',
    };
  }

  Map<String, String> get _jsonHeaders {
    return <String, String>{
      ..._headers,
      'Content-Type': 'application/json',
    };
  }

  Future<List<AppUser>> listUsers() async {
    final http.Response response = await _client.get(
      _baseUri.resolve('/users'),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      throw ChatApiException(
        _readErrorMessage(
          response,
          fallback:
              'User loading failed with status code '
              '${response.statusCode}.',
        ),
      );
    }

    final Object? decodedBody = jsonDecode(response.body);

    if (decodedBody is! List<dynamic>) {
      throw const ChatApiException('The server returned an invalid user list.');
    }

    return decodedBody
        .map((dynamic item) {
          if (item is! Map<String, dynamic>) {
            throw const ChatApiException(
              'The server returned an invalid user.',
            );
          }

          return AppUser.fromJson(item);
        })
        .toList(growable: false);
  }

  Future<List<ChatMessage>> listConversation({
    required int otherUserId,
    int limit = 100,
  }) async {
    final Uri requestUri = _baseUri
        .resolve('/messages/conversation/$otherUserId')
        .replace(queryParameters: <String, String>{'limit': limit.toString()});

    final http.Response response = await _client.get(
      requestUri,
      headers: _headers,
    );

    if (response.statusCode != 200) {
      throw ChatApiException(
        _readErrorMessage(
          response,
          fallback:
              'Conversation loading failed with status code '
              '${response.statusCode}.',
        ),
      );
    }

    final Object? decodedBody = jsonDecode(response.body);

    if (decodedBody is! List<dynamic>) {
      throw const ChatApiException(
        'The server returned an invalid conversation.',
      );
    }

    return decodedBody
        .map((dynamic item) {
          if (item is! Map<String, dynamic>) {
            throw const ChatApiException(
              'The server returned an invalid message.',
            );
          }

          return messageFromJson(item);
        })
        .toList(growable: false);
  }

  Future<List<ChatMessage>> searchConversation({
    required int otherUserId,
    required String query,
    int limit = 100,
  }) async {
    final Uri requestUri = _baseUri
        .resolve('/messages/conversation/$otherUserId/search')
        .replace(
          queryParameters: <String, String>{
            'query': query,
            'limit': limit.toString(),
          },
        );

    final http.Response response = await _client.get(
      requestUri,
      headers: _headers,
    );

    if (response.statusCode != 200) {
      throw ChatApiException(
        _readErrorMessage(
          response,
          fallback:
              'Message search failed with status code '
              '${response.statusCode}.',
        ),
      );
    }

    final Object? decodedBody = jsonDecode(response.body);

    if (decodedBody is! List<dynamic>) {
      throw const ChatApiException(
        'The server returned an invalid search result.',
      );
    }

    return decodedBody
        .map((dynamic item) {
          if (item is! Map<String, dynamic>) {
            throw const ChatApiException(
              'The server returned an invalid message.',
            );
          }

          return messageFromJson(item);
        })
        .toList(growable: false);
  }

  Future<ChatMessage> sendTextMessage({
    required int recipientId,
    required String content,
    int? replyToMessageId,
  }) {
    return _createMessage(
      recipientId: recipientId,
      content: content,
      messageType: 'text',
      replyToMessageId: replyToMessageId,
    );
  }

  Future<ChatMessage> sendPhotoMessage({
    required int recipientId,
    required List<ChatPhotoAttachment> photos,
    int? replyToMessageId,
  }) {
    return _createMessage(
      recipientId: recipientId,
      messageType: 'photo',
      replyToMessageId: replyToMessageId,
      metadata: <String, Object?>{
        'photos': photos.map((ChatPhotoAttachment photo) {
          return <String, Object?>{
            'asset_id': photo.assetId,
            'preview_base64': base64Encode(photo.previewBytes),
            'width': photo.width,
            'height': photo.height,
          };
        }).toList(growable: false),
      },
    );
  }

  Future<ChatMessage> sendFileMessage({
    required int recipientId,
    required ChatFileAttachment file,
    int? replyToMessageId,
  }) {
    return _createMessage(
      recipientId: recipientId,
      messageType: 'file',
      replyToMessageId: replyToMessageId,
      metadata: <String, Object?>{
        'file': <String, Object?>{
          'name': file.name,
          'size_bytes': file.sizeBytes,
        },
      },
    );
  }

  Future<ChatMessage> sendVoiceMemoMessage({
    required int recipientId,
    required Duration duration,
    int? replyToMessageId,
  }) {
    return _createMessage(
      recipientId: recipientId,
      messageType: 'voice_memo',
      replyToMessageId: replyToMessageId,
      metadata: <String, Object?>{
        'duration_ms': duration.inMilliseconds,
      },
    );
  }

  Future<ChatMessage> sendCallMessage({
    required int recipientId,
    required ChatCallAttachment call,
    int? replyToMessageId,
  }) {
    return _createMessage(
      recipientId: recipientId,
      messageType: 'call',
      replyToMessageId: replyToMessageId,
      metadata: <String, Object?>{
        'kind': _callKindToApi(call.kind),
        'outcome': _callOutcomeToApi(call.outcome),
        'duration_ms': call.duration.inMilliseconds,
      },
    );
  }

  Future<ChatMessage> editTextMessage({
    required int messageId,
    required String content,
  }) async {
    final http.Response response = await _client.patch(
      _baseUri.resolve('/messages/$messageId'),
      headers: _jsonHeaders,
      body: jsonEncode(<String, Object?>{
        'content': content,
      }),
    );

    if (response.statusCode != 200) {
      throw ChatApiException(
        _readErrorMessage(
          response,
          fallback:
              'Message editing failed with status code '
              '${response.statusCode}.',
        ),
      );
    }

    final Object? decodedBody = jsonDecode(response.body);

    if (decodedBody is! Map<String, dynamic>) {
      throw const ChatApiException(
        'The server returned an invalid message.',
      );
    }

    return messageFromJson(decodedBody);
  }

  Future<void> deleteMessage({
    required int messageId,
  }) async {
    final http.Response response = await _client.delete(
      _baseUri.resolve('/messages/$messageId'),
      headers: _headers,
    );

    if (response.statusCode != 204) {
      throw ChatApiException(
        _readErrorMessage(
          response,
          fallback:
              'Message deletion failed with status code '
              '${response.statusCode}.',
        ),
      );
    }
  }

  Future<void> markConversationAsRead({
    required int otherUserId,
  }) async {
    final http.Response response = await _client.patch(
      _baseUri.resolve('/messages/conversation/$otherUserId/read'),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      throw ChatApiException(
        _readErrorMessage(
          response,
          fallback:
              'Read receipt update failed with status code '
              '${response.statusCode}.',
        ),
      );
    }
  }

  Future<ChatMessage> _createMessage({
    required int recipientId,
    required String messageType,
    String content = '',
    Map<String, Object?>? metadata,
    int? replyToMessageId,
  }) async {
    final Map<String, Object?> body = <String, Object?>{
      'recipient_id': recipientId,
      'content': content,
      'message_type': messageType,
      'metadata': ?metadata,
      'reply_to_message_id': ?replyToMessageId,
    };

    final http.Response response = await _client.post(
      _baseUri.resolve('/messages'),
      headers: _jsonHeaders,
      body: jsonEncode(body),
    );

    if (response.statusCode != 201) {
      throw ChatApiException(
        _readErrorMessage(
          response,
          fallback:
              'Message sending failed with status code '
              '${response.statusCode}.',
        ),
      );
    }

    final Object? decodedBody = jsonDecode(response.body);

    if (decodedBody is! Map<String, dynamic>) {
      throw const ChatApiException(
        'The server returned an invalid message.',
      );
    }

    return messageFromJson(decodedBody);
  }

  ChatMessage messageFromJson(Map<String, dynamic> json) {
    final String translationStatus = json['translation_status'] as String;
    final String messageType = json['message_type'] as String? ?? 'text';
    final Map<String, dynamic>? metadata = _optionalMap(json['metadata']);
    final bool translates = messageType == 'text';

    return ChatMessage(
      id: json['id'] as int,
      senderId: json['sender_id'] as int,
      recipientId: json['recipient_id'] as int,
      content: json['content'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      editedAt: _optionalDateTime(json['edited_at']),
      readAt: _optionalDateTime(json['read_at']),
      translatedContent: translates ? json['translated_content'] as String? : null,
      translationStatus: translates
          ? _translationStatusFromApi(translationStatus)
          : ChatTranslationStatus.none,
      translationFailureReason: translates && translationStatus == 'failed'
          ? 'Server translation failed'
          : null,
      replyTo: _replyReferenceFromJson(json['reply_to']),
      photoAttachments: messageType == 'photo' && metadata != null
          ? _photosFromMetadata(metadata)
          : const <ChatPhotoAttachment>[],
      fileAttachment: messageType == 'file' && metadata != null
          ? _fileFromMetadata(metadata)
          : null,
      voiceMemoAttachment: messageType == 'voice_memo' && metadata != null
          ? _voiceMemoFromMetadata(metadata)
          : null,
      callAttachment: messageType == 'call' && metadata != null
          ? _callFromMetadata(metadata)
          : null,
    );
  }

  ChatReplyReference? _replyReferenceFromJson(Object? value) {
    if (value == null) {
      return null;
    }

    if (value is! Map<String, dynamic>) {
      throw const ChatApiException(
        'The server returned an invalid reply reference.',
      );
    }

    return ChatReplyReference(
      messageId: value['message_id'] as int,
      senderId: value['sender_id'] as int,
      content: value['content'] as String,
    );
  }

  List<ChatPhotoAttachment> _photosFromMetadata(
    Map<String, dynamic> metadata,
  ) {
    final Object? photos = metadata['photos'];

    if (photos is! List<dynamic>) {
      throw const ChatApiException(
        'The server returned an invalid photo message.',
      );
    }

    return photos.map((dynamic item) {
      if (item is! Map<String, dynamic>) {
        throw const ChatApiException(
          'The server returned an invalid photo attachment.',
        );
      }

      final Object? previewBase64 = item['preview_base64'];

      if (previewBase64 is! String) {
        throw const ChatApiException(
          'The server returned a photo without a preview.',
        );
      }

      return ChatPhotoAttachment(
        assetId: item['asset_id'] as String,
        previewBytes: base64Decode(previewBase64),
        width: item['width'] as int,
        height: item['height'] as int,
      );
    }).toList(growable: false);
  }

  ChatFileAttachment _fileFromMetadata(Map<String, dynamic> metadata) {
    final Object? file = metadata['file'];

    if (file is! Map<String, dynamic>) {
      throw const ChatApiException(
        'The server returned an invalid file message.',
      );
    }

    return ChatFileAttachment(
      name: file['name'] as String,
      sizeBytes: file['size_bytes'] as int,
    );
  }

  ChatVoiceMemoAttachment _voiceMemoFromMetadata(
    Map<String, dynamic> metadata,
  ) {
    final int durationMs = metadata['duration_ms'] as int;

    return ChatVoiceMemoAttachment(
      duration: Duration(milliseconds: durationMs),
    );
  }

  ChatCallAttachment _callFromMetadata(Map<String, dynamic> metadata) {
    final int durationMs = metadata['duration_ms'] as int;

    return ChatCallAttachment(
      kind: _callKindFromApi(metadata['kind'] as String),
      outcome: _callOutcomeFromApi(metadata['outcome'] as String),
      duration: Duration(milliseconds: durationMs),
    );
  }

  ChatTranslationStatus _translationStatusFromApi(String status) {
    return switch (status) {
      'pending' => ChatTranslationStatus.translating,
      'completed' => ChatTranslationStatus.translated,
      'failed' => ChatTranslationStatus.failed,
      _ => throw ChatApiException(
        'The server returned an unknown '
        'translation status: $status',
      ),
    };
  }

  String _callKindToApi(ChatCallKind kind) {
    return switch (kind) {
      ChatCallKind.voice => 'voice',
      ChatCallKind.video => 'video',
    };
  }

  ChatCallKind _callKindFromApi(String kind) {
    return switch (kind) {
      'voice' => ChatCallKind.voice,
      'video' => ChatCallKind.video,
      _ => throw ChatApiException(
        'The server returned an unknown call kind: $kind',
      ),
    };
  }

  String _callOutcomeToApi(ChatCallOutcome outcome) {
    return switch (outcome) {
      ChatCallOutcome.started => 'started',
      ChatCallOutcome.ended => 'ended',
      ChatCallOutcome.cancelled => 'cancelled',
      ChatCallOutcome.missed => 'missed',
      ChatCallOutcome.noAnswer => 'no_answer',
    };
  }

  ChatCallOutcome _callOutcomeFromApi(String outcome) {
    return switch (outcome) {
      'started' => ChatCallOutcome.started,
      'ended' => ChatCallOutcome.ended,
      'cancelled' => ChatCallOutcome.cancelled,
      'missed' => ChatCallOutcome.missed,
      'no_answer' => ChatCallOutcome.noAnswer,
      _ => throw ChatApiException(
        'The server returned an unknown call outcome: $outcome',
      ),
    };
  }

  Map<String, dynamic>? _optionalMap(Object? value) {
    if (value == null) {
      return null;
    }

    if (value is! Map<String, dynamic>) {
      throw const ChatApiException(
        'The server returned invalid message metadata.',
      );
    }

    return value;
  }

  DateTime? _optionalDateTime(Object? value) {
    if (value == null) {
      return null;
    }

    if (value is! String) {
      throw const ChatApiException('The server returned an invalid date.');
    }

    return DateTime.parse(value);
  }

  String _readErrorMessage(http.Response response, {required String fallback}) {
    try {
      final Object? decodedBody = jsonDecode(response.body);

      if (decodedBody is Map<String, dynamic>) {
        final Object? detail = decodedBody['detail'];

        if (detail is String && detail.trim().isNotEmpty) {
          return detail;
        }
      }
    } on FormatException {
      return fallback;
    }

    return fallback;
  }
}

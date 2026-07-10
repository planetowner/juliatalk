import 'dart:convert';
import 'dart:typed_data';

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

  static final RegExp _urlPattern = RegExp(
    r'''(?:(?:https?):\/\/|www\.)[^\s<>'"]+''',
    caseSensitive: false,
  );
  static const String _trailingUrlPunctuation = '.,!?;:)]}…';

  Map<String, String> get _headers {
    return <String, String>{
      'Accept': 'application/json',
      'Authorization': 'Bearer $_accessToken',
    };
  }

  Map<String, String> get _jsonHeaders {
    return <String, String>{..._headers, 'Content-Type': 'application/json'};
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
    required String otherUserId,
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
    required String otherUserId,
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

  Future<int> countUnreadMessages({String? excludeUserId}) async {
    final Map<String, String>? queryParameters = excludeUserId == null
        ? null
        : <String, String>{'exclude_user_id': excludeUserId};
    final Uri requestUri = _baseUri
        .resolve('/messages/unread-count')
        .replace(queryParameters: queryParameters);

    final http.Response response = await _client.get(
      requestUri,
      headers: _headers,
    );

    if (response.statusCode != 200) {
      throw ChatApiException(
        _readErrorMessage(
          response,
          fallback:
              'Unread count loading failed with status code '
              '${response.statusCode}.',
        ),
      );
    }

    final Object? decodedBody = jsonDecode(response.body);

    if (decodedBody is! Map<String, dynamic>) {
      throw const ChatApiException(
        'The server returned an invalid unread count.',
      );
    }

    final Object? unreadCount = decodedBody['unread_count'];

    if (unreadCount is int && unreadCount >= 0) {
      return unreadCount;
    }

    throw const ChatApiException(
      'The server returned an invalid unread count.',
    );
  }

  Future<ChatMessage> sendTextMessage({
    required String recipientId,
    required String content,
    String? replyToMessageId,
  }) {
    final String? previewUrl = _firstUrlInText(content);

    return _createMessage(
      recipientId: recipientId,
      content: content,
      messageType: previewUrl == null ? 'text' : 'link',
      metadata: previewUrl == null
          ? null
          : <String, Object?>{
              'url': previewUrl,
              'domain': _domainForUrl(previewUrl),
            },
      replyToMessageId: replyToMessageId,
    );
  }

  Future<ChatMessage> sendPhotoMessage({
    required String recipientId,
    required List<ChatPhotoAttachment> photos,
    String? replyToMessageId,
  }) async {
    final List<String> mediaAssetIds = <String>[];

    for (final ChatPhotoAttachment photo in photos) {
      final String mediaAssetId =
          photo.mediaAssetId ??
          await _uploadMediaAsset(
            kind: 'photo',
            fileName: photo.fileName ?? '${photo.assetId}.jpg',
            mimeType: photo.mimeType ?? 'image/jpeg',
            sizeBytes: photo.sizeBytes ?? photo.uploadBytes?.length ?? 0,
            bytes: photo.uploadBytes,
            width: photo.width,
            height: photo.height,
          );

      mediaAssetIds.add(mediaAssetId);
    }

    final ChatMessage message = await _createMessage(
      recipientId: recipientId,
      messageType: 'photo',
      replyToMessageId: replyToMessageId,
      metadata: <String, Object?>{'media_asset_ids': mediaAssetIds},
    );

    return _withLocalPhotoPreviews(message, photos);
  }

  Future<ChatMessage> sendFileMessage({
    required String recipientId,
    required ChatFileAttachment file,
    String? replyToMessageId,
  }) async {
    final String mediaAssetId =
        file.mediaAssetId ??
        await _uploadMediaAsset(
          kind: 'file',
          fileName: file.name,
          mimeType: file.mimeType ?? 'application/octet-stream',
          sizeBytes: file.sizeBytes,
          bytes: file.uploadBytes,
        );

    return _createMessage(
      recipientId: recipientId,
      messageType: 'file',
      replyToMessageId: replyToMessageId,
      metadata: <String, Object?>{
        'media_asset_ids': <String>[mediaAssetId],
      },
    );
  }

  Future<ChatMessage> sendVoiceMemoMessage({
    required String recipientId,
    required ChatVoiceMemoAttachment voiceMemo,
    String? replyToMessageId,
  }) async {
    final Uint8List? audioBytes = voiceMemo.audioBytes;
    final List<double> waveformSamples = voiceMemo.waveformSamples
        .map((double sample) => sample.clamp(0, 1).toDouble())
        .toList(growable: false);
    final String mediaAssetId;

    if (voiceMemo.mediaAssetId != null) {
      mediaAssetId = voiceMemo.mediaAssetId!;
    } else {
      mediaAssetId = await _uploadMediaAsset(
        kind: 'voice_memo',
        fileName: voiceMemo.fileName ?? 'voice-memo.m4a',
        mimeType: voiceMemo.mimeType ?? 'audio/mp4',
        sizeBytes: voiceMemo.sizeBytes ?? audioBytes?.length ?? 0,
        bytes: audioBytes,
        duration: voiceMemo.duration,
        metadata: waveformSamples.isEmpty
            ? null
            : <String, Object?>{'waveform_samples': waveformSamples},
      );
    }

    final ChatMessage message = await _createMessage(
      recipientId: recipientId,
      messageType: 'voice_memo',
      replyToMessageId: replyToMessageId,
      metadata: <String, Object?>{
        'media_asset_ids': <String>[mediaAssetId],
        if (waveformSamples.isNotEmpty) 'waveform_samples': waveformSamples,
      },
    );

    return _withLocalVoiceMemoPreview(message, voiceMemo);
  }

  Future<String> _uploadMediaAsset({
    required String kind,
    required String fileName,
    required String mimeType,
    required int sizeBytes,
    required Uint8List? bytes,
    int? width,
    int? height,
    Duration? duration,
    Map<String, Object?>? metadata,
  }) async {
    if (bytes == null || bytes.isEmpty) {
      throw const ChatApiException('The selected media file is empty.');
    }

    final http.Response createResponse = await _client.post(
      _baseUri.resolve('/media-assets'),
      headers: _jsonHeaders,
      body: jsonEncode(<String, Object?>{
        'kind': kind,
        'file_name': fileName,
        'mime_type': mimeType,
        'size_bytes': sizeBytes > 0 ? sizeBytes : bytes.length,
        'width': ?width,
        'height': ?height,
        if (duration != null) 'duration_ms': duration.inMilliseconds,
        if (metadata != null && metadata.isNotEmpty) 'metadata': metadata,
      }),
    );

    if (createResponse.statusCode != 201) {
      throw ChatApiException(
        _readErrorMessage(
          createResponse,
          fallback:
              'Media upload preparation failed with status code '
              '${createResponse.statusCode}.',
        ),
      );
    }

    final Object? decodedBody = jsonDecode(createResponse.body);

    if (decodedBody is! Map<String, dynamic>) {
      throw const ChatApiException(
        'The server returned an invalid media upload.',
      );
    }

    final String mediaAssetId = _requiredString(
      decodedBody['media_asset_id'],
      'media_asset_id',
    );
    final String uploadUrl = _requiredString(
      decodedBody['upload_url'],
      'upload_url',
    );
    final Object? uploadHeadersJson = decodedBody['upload_headers'];
    final Map<String, String> uploadHeaders =
        uploadHeadersJson is Map<String, dynamic>
        ? uploadHeadersJson.map(
            (String key, dynamic value) =>
                MapEntry<String, String>(key, value.toString()),
          )
        : <String, String>{'Content-Type': mimeType};

    final http.Response uploadResponse = await _client.put(
      Uri.parse(uploadUrl),
      headers: uploadHeaders,
      body: bytes,
    );

    if (uploadResponse.statusCode < 200 || uploadResponse.statusCode >= 300) {
      throw ChatApiException(
        'Media upload failed with status code '
        '${uploadResponse.statusCode}.',
      );
    }

    final http.Response completeResponse = await _client.post(
      _baseUri.resolve('/media-assets/$mediaAssetId/complete'),
      headers: _headers,
    );

    if (completeResponse.statusCode != 200) {
      throw ChatApiException(
        _readErrorMessage(
          completeResponse,
          fallback:
              'Media upload completion failed with status code '
              '${completeResponse.statusCode}.',
        ),
      );
    }

    return mediaAssetId;
  }

  Future<Uri> createMediaAssetAccessUrl({required String mediaAssetId}) async {
    final http.Response response = await _client.get(
      _baseUri.resolve('/media-assets/$mediaAssetId/access'),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      throw ChatApiException(
        _readErrorMessage(
          response,
          fallback:
              'Media URL creation failed with status code '
              '${response.statusCode}.',
        ),
      );
    }

    final Object? decodedBody = jsonDecode(response.body);

    if (decodedBody is! Map<String, dynamic>) {
      throw const ChatApiException('The server returned an invalid media URL.');
    }

    return Uri.parse(_requiredString(decodedBody['access_url'], 'access_url'));
  }

  ChatMessage _withLocalPhotoPreviews(
    ChatMessage message,
    List<ChatPhotoAttachment> localPhotos,
  ) {
    final List<ChatPhotoAttachment> serverPhotos = message.photoAttachments;

    if (serverPhotos.isEmpty || localPhotos.isEmpty) {
      return message;
    }

    return message.copyWith(
      photoAttachments: List<ChatPhotoAttachment>.generate(
        serverPhotos.length,
        (int index) {
          final ChatPhotoAttachment serverPhoto = serverPhotos[index];

          if (index >= localPhotos.length) {
            return serverPhoto;
          }

          final ChatPhotoAttachment localPhoto = localPhotos[index];

          return ChatPhotoAttachment(
            assetId: serverPhoto.assetId,
            mediaAssetId: serverPhoto.mediaAssetId,
            previewBytes: serverPhoto.previewBytes ?? localPhoto.previewBytes,
            width: serverPhoto.width > 0 ? serverPhoto.width : localPhoto.width,
            height: serverPhoto.height > 0
                ? serverPhoto.height
                : localPhoto.height,
            fileName: serverPhoto.fileName ?? localPhoto.fileName,
            mimeType: serverPhoto.mimeType ?? localPhoto.mimeType,
            sizeBytes: serverPhoto.sizeBytes ?? localPhoto.sizeBytes,
            uploadBytes: localPhoto.uploadBytes,
          );
        },
        growable: false,
      ),
    );
  }

  ChatMessage _withLocalVoiceMemoPreview(
    ChatMessage message,
    ChatVoiceMemoAttachment localVoiceMemo,
  ) {
    final ChatVoiceMemoAttachment? serverVoiceMemo =
        message.voiceMemoAttachment;

    if (serverVoiceMemo == null) {
      return message;
    }

    return message.copyWith(
      voiceMemoAttachment: ChatVoiceMemoAttachment(
        duration: serverVoiceMemo.duration > Duration.zero
            ? serverVoiceMemo.duration
            : localVoiceMemo.duration,
        audioBytes: serverVoiceMemo.audioBytes ?? localVoiceMemo.audioBytes,
        mimeType: serverVoiceMemo.mimeType ?? localVoiceMemo.mimeType,
        fileName: serverVoiceMemo.fileName ?? localVoiceMemo.fileName,
        sizeBytes: serverVoiceMemo.sizeBytes ?? localVoiceMemo.sizeBytes,
        localPath: localVoiceMemo.localPath ?? serverVoiceMemo.localPath,
        mediaAssetId:
            serverVoiceMemo.mediaAssetId ?? localVoiceMemo.mediaAssetId,
        waveformSamples: serverVoiceMemo.waveformSamples.isNotEmpty
            ? serverVoiceMemo.waveformSamples
            : localVoiceMemo.waveformSamples,
      ),
    );
  }

  Future<ChatMessage> sendCallMessage({
    required String recipientId,
    required ChatCallAttachment call,
    String? replyToMessageId,
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
    required String messageId,
    required String content,
  }) async {
    final http.Response response = await _client.patch(
      _baseUri.resolve('/messages/$messageId'),
      headers: _jsonHeaders,
      body: jsonEncode(<String, Object?>{'content': content}),
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
      throw const ChatApiException('The server returned an invalid message.');
    }

    return messageFromJson(decodedBody);
  }

  Future<void> deleteMessage({required String messageId}) async {
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

  Future<void> markConversationAsRead({required String otherUserId}) async {
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
    required String recipientId,
    required String messageType,
    String content = '',
    Map<String, Object?>? metadata,
    String? replyToMessageId,
  }) async {
    final Map<String, Object?> body = <String, Object?>{
      'recipient_id': recipientId,
      'content': content,
      'message_type': messageType,
      'created_at': DateTime.now().toUtc().toIso8601String(),
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
      throw const ChatApiException('The server returned an invalid message.');
    }

    return messageFromJson(decodedBody);
  }

  ChatMessage messageFromJson(Map<String, dynamic> json) {
    final String translationStatus = json['translation_status'] as String;
    final String messageType = json['message_type'] as String? ?? 'text';
    final Map<String, dynamic>? metadata = _optionalMap(json['metadata']);
    final String content = json['content'] as String;
    final bool translates = messageType == 'text';

    return ChatMessage(
      id: _requiredString(json['id'], 'id'),
      senderId: _requiredString(json['sender_id'], 'sender_id'),
      recipientId: _requiredString(json['recipient_id'], 'recipient_id'),
      content: content,
      createdAt: _dateTimeFromApi(json['created_at']),
      editedAt: _optionalDateTime(json['edited_at']),
      readAt: _optionalDateTime(json['read_at']),
      translatedContent: translates
          ? json['translated_content'] as String?
          : null,
      sourceLanguage: translates ? json['source_language'] as String? : null,
      translatedLanguage: translates
          ? json['translated_language'] as String?
          : null,
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
      fileAttachment:
          (messageType == 'file' || messageType == 'video') && metadata != null
          ? _fileFromMetadata(metadata)
          : null,
      voiceMemoAttachment: messageType == 'voice_memo' && metadata != null
          ? _voiceMemoFromMetadata(metadata)
          : null,
      callAttachment: messageType == 'call' && metadata != null
          ? _callFromMetadata(metadata)
          : null,
      linkPreview: messageType == 'link'
          ? _linkPreviewFromMetadata(metadata, content)
          : null,
    );
  }

  String? _firstUrlInText(String content) {
    final RegExpMatch? match = _urlPattern.firstMatch(content);

    if (match == null) {
      return null;
    }

    String url = match.group(0)!.trimRight();

    while (url.isNotEmpty &&
        _trailingUrlPunctuation.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }

    if (url.toLowerCase().startsWith('www.')) {
      return 'https://$url';
    }

    return url;
  }

  String _domainForUrl(String url) {
    final Uri? parsedUrl = Uri.tryParse(url);
    String domain = parsedUrl?.host ?? '';

    if (domain.isEmpty) {
      return url;
    }

    if (domain.startsWith('www.')) {
      domain = domain.substring(4);
    }

    return domain;
  }

  ChatLinkPreview? _linkPreviewFromMetadata(
    Map<String, dynamic>? metadata,
    String content,
  ) {
    final Object? metadataUrl = metadata == null ? null : metadata['url'];
    final Object? metadataCanonicalUrl = metadata == null
        ? null
        : metadata['canonical_url'];
    final Object? metadataDomain = metadata == null ? null : metadata['domain'];
    final Object? metadataTitle = metadata == null ? null : metadata['title'];
    final Object? metadataDescription = metadata == null
        ? null
        : metadata['description'];
    final Object? metadataSiteName = metadata == null
        ? null
        : metadata['site_name'];
    final Object? metadataImageUrl = metadata == null
        ? null
        : metadata['image_url'];
    final String? url =
        _optionalString(metadataUrl) ?? _firstUrlInText(content);

    if (url == null) {
      return null;
    }

    final String? canonicalUrl = _optionalString(metadataCanonicalUrl);
    final String domain =
        _optionalString(metadataDomain) ?? _domainForUrl(canonicalUrl ?? url);

    return ChatLinkPreview(
      url: url,
      canonicalUrl: canonicalUrl,
      domain: domain,
      title: _optionalString(metadataTitle),
      description: _optionalString(metadataDescription),
      siteName: _optionalString(metadataSiteName),
      imageUrl: _optionalString(metadataImageUrl),
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
      messageId: _requiredString(value['message_id'], 'message_id'),
      senderId: _requiredString(value['sender_id'], 'sender_id'),
      content: value['content'] as String,
    );
  }

  List<ChatPhotoAttachment> _photosFromMetadata(Map<String, dynamic> metadata) {
    final Object? photos = metadata['photos'];

    if (photos is! List<dynamic>) {
      throw const ChatApiException(
        'The server returned an invalid photo message.',
      );
    }

    return photos
        .map((dynamic item) {
          if (item is! Map<String, dynamic>) {
            throw const ChatApiException(
              'The server returned an invalid photo attachment.',
            );
          }

          final Object? previewBase64 = item['preview_base64'];
          final Uint8List? previewBytes =
              previewBase64 is String && previewBase64.isNotEmpty
              ? base64Decode(previewBase64)
              : null;
          final String mediaAssetId = _requiredString(
            item['media_asset_id'],
            'media_asset_id',
          );

          return ChatPhotoAttachment(
            assetId: item['asset_id'] as String? ?? mediaAssetId,
            mediaAssetId: mediaAssetId,
            previewBytes: previewBytes,
            width: item['width'] as int? ?? 0,
            height: item['height'] as int? ?? 0,
            fileName: item['file_name'] as String?,
            mimeType: item['mime_type'] as String?,
            sizeBytes: item['size_bytes'] as int?,
          );
        })
        .toList(growable: false);
  }

  ChatFileAttachment _fileFromMetadata(Map<String, dynamic> metadata) {
    final Object? file = metadata['file'] ?? metadata['video'];

    if (file is! Map<String, dynamic>) {
      throw const ChatApiException(
        'The server returned an invalid file message.',
      );
    }

    final String fileName =
        (file['name'] as String?) ?? (file['file_name'] as String?) ?? '';

    return ChatFileAttachment(
      name: fileName.isEmpty ? 'File' : fileName,
      mediaAssetId: file['media_asset_id'] as String?,
      mimeType: file['mime_type'] as String?,
      sizeBytes: file['size_bytes'] as int? ?? 0,
    );
  }

  ChatVoiceMemoAttachment _voiceMemoFromMetadata(
    Map<String, dynamic> metadata,
  ) {
    final int durationMs = metadata['duration_ms'] as int;
    final Object? audioBase64 = metadata['audio_base64'];
    final Uint8List? audioBytes =
        audioBase64 is String && audioBase64.isNotEmpty
        ? base64Decode(audioBase64)
        : null;

    return ChatVoiceMemoAttachment(
      duration: Duration(milliseconds: durationMs),
      audioBytes: audioBytes,
      mimeType: metadata['mime_type'] as String?,
      fileName: metadata['file_name'] as String?,
      sizeBytes: metadata['size_bytes'] as int?,
      mediaAssetId: metadata['media_asset_id'] as String?,
      waveformSamples: _waveformSamplesFromJson(metadata['waveform_samples']),
    );
  }

  List<double> _waveformSamplesFromJson(Object? json) {
    if (json is! List) {
      return const <double>[];
    }

    final List<double> samples = <double>[];

    for (final Object? sample in json) {
      if (sample is num) {
        samples.add(sample.toDouble().clamp(0, 1).toDouble());
      }
    }

    return List<double>.unmodifiable(samples);
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

  String? _optionalString(Object? value) {
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }

    return null;
  }

  String _requiredString(Object? value, String fieldName) {
    if (value is String && value.isNotEmpty) {
      return value;
    }

    throw ChatApiException('The server returned an invalid $fieldName.');
  }

  DateTime _dateTimeFromApi(Object? value) {
    if (value is String) {
      final DateTime parsed = DateTime.parse(value);

      if (parsed.isUtc) {
        return parsed;
      }

      return DateTime.utc(
        parsed.year,
        parsed.month,
        parsed.day,
        parsed.hour,
        parsed.minute,
        parsed.second,
        parsed.millisecond,
        parsed.microsecond,
      );
    }

    throw const ChatApiException('The server returned an invalid date.');
  }

  DateTime? _optionalDateTime(Object? value) {
    if (value == null) {
      return null;
    }

    if (value is! String) {
      throw const ChatApiException('The server returned an invalid date.');
    }

    return _dateTimeFromApi(value);
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

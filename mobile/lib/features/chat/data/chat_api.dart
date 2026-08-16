import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../auth/domain/app_user.dart';
import '../domain/chat_link.dart';
import '../domain/chat_message.dart';
import 'chat_api_exception.dart';
import 'chat_realtime_event_state.dart';
import 'device_link_preview_fetcher.dart';
import 'photo_send_diagnostics.dart';

void _logPhotoSendTiming(
  String stage,
  Stopwatch stopwatch, {
  required int photoCount,
  int? photoIndex,
  int? originalBytes,
  int? previewBytes,
}) {
  final List<String> fields = <String>[
    '[photo-send]',
    'stage=$stage',
    'elapsed_ms=${(stopwatch.elapsedMicroseconds / 1000).toStringAsFixed(1)}',
    'photo_count=$photoCount',
    if (photoIndex != null) 'photo_index=$photoIndex',
    if (originalBytes != null) 'original_bytes=$originalBytes',
    if (previewBytes != null) 'preview_bytes=$previewBytes',
  ];
  recordPhotoSendDiagnostic(fields.join(' '));
}

final class ChatConversationPage {
  ChatConversationPage({
    required List<ChatMessage> messages,
    required this.hasMore,
  }) : messages = List<ChatMessage>.unmodifiable(messages);

  final List<ChatMessage> messages;
  final bool hasMore;
}

final class ChatConversationContext {
  ChatConversationContext({
    required List<ChatMessage> messages,
    required this.hasMoreOlder,
    required this.hasMoreNewer,
  }) : messages = List<ChatMessage>.unmodifiable(messages);

  final List<ChatMessage> messages;
  final bool hasMoreOlder;
  final bool hasMoreNewer;
}

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

  static const Duration _conversationRequestTimeout = Duration(seconds: 15);
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

  Future<ChatConversationPage> listConversation({
    required String otherUserId,
    int limit = 100,
    String? beforeMessageId,
    String? afterMessageId,
  }) async {
    if (beforeMessageId != null && afterMessageId != null) {
      throw ArgumentError(
        'Only one conversation cursor direction can be requested.',
      );
    }

    final Uri requestUri = _baseUri
        .resolve('/messages/conversation/$otherUserId')
        .replace(
          queryParameters: <String, String>{
            'limit': limit.toString(),
            'before_message_id': ?beforeMessageId,
            'after_message_id': ?afterMessageId,
          },
        );

    final http.Response response;

    try {
      response = await _client
          .get(requestUri, headers: _headers)
          .timeout(_conversationRequestTimeout);
    } on TimeoutException {
      throw const ChatApiException(
        'Conversation loading timed out.',
        retryable: true,
      );
    } on http.ClientException {
      throw const ChatApiException(
        'Conversation loading failed because of a network error.',
        retryable: true,
      );
    }

    if (response.statusCode != 200) {
      throw ChatApiException(
        _readErrorMessage(
          response,
          fallback:
              'Conversation loading failed with status code '
              '${response.statusCode}.',
        ),
        retryable:
            response.statusCode == 429 ||
            (response.statusCode >= 500 && response.statusCode < 600),
        statusCode: response.statusCode,
      );
    }

    final Object? decodedBody = jsonDecode(response.body);

    if (decodedBody is! List<dynamic>) {
      throw const ChatApiException(
        'The server returned an invalid conversation.',
      );
    }

    final List<ChatMessage> messages = decodedBody
        .map((dynamic item) {
          if (item is! Map<String, dynamic>) {
            throw const ChatApiException(
              'The server returned an invalid message.',
            );
          }

          return messageFromJson(item);
        })
        .toList(growable: false);

    final String? hasMoreHeader = response.headers['x-has-more'];
    final bool hasMore =
        hasMoreHeader == 'true' ||
        (hasMoreHeader == null && messages.length == limit);

    return ChatConversationPage(messages: messages, hasMore: hasMore);
  }

  Future<ChatConversationContext> getConversationMessageContext({
    required String otherUserId,
    required String messageId,
    int olderLimit = 30,
    int newerLimit = 30,
  }) async {
    final Uri requestUri = _baseUri
        .resolve('/messages/conversation/$otherUserId/around/$messageId')
        .replace(
          queryParameters: <String, String>{
            'older_limit': olderLimit.toString(),
            'newer_limit': newerLimit.toString(),
          },
        );
    final http.Response response;

    try {
      response = await _client
          .get(requestUri, headers: _headers)
          .timeout(_conversationRequestTimeout);
    } on TimeoutException {
      throw const ChatApiException(
        'Message context loading timed out.',
        retryable: true,
      );
    } on http.ClientException {
      throw const ChatApiException(
        'Message context loading failed because of a network error.',
        retryable: true,
      );
    }

    if (response.statusCode != 200) {
      throw ChatApiException(
        _readErrorMessage(
          response,
          fallback:
              'Message context loading failed with status code '
              '${response.statusCode}.',
        ),
        retryable:
            response.statusCode == 429 ||
            (response.statusCode >= 500 && response.statusCode < 600),
        statusCode: response.statusCode,
      );
    }

    final Object? decodedBody = jsonDecode(response.body);

    if (decodedBody is! Map<String, dynamic> ||
        decodedBody['messages'] is! List<dynamic> ||
        decodedBody['has_more_older'] is! bool ||
        decodedBody['has_more_newer'] is! bool) {
      throw const ChatApiException(
        'The server returned an invalid message context.',
      );
    }

    final List<ChatMessage> messages =
        (decodedBody['messages'] as List<dynamic>)
            .map((dynamic item) {
              if (item is! Map<String, dynamic>) {
                throw const ChatApiException(
                  'The server returned an invalid message.',
                );
              }

              return messageFromJson(item);
            })
            .toList(growable: false);

    return ChatConversationContext(
      messages: messages,
      hasMoreOlder: decodedBody['has_more_older'] as bool,
      hasMoreNewer: decodedBody['has_more_newer'] as bool,
    );
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

  Future<int> countUnreadMessages({
    String? excludeUserId,
    String? fromUserId,
  }) async {
    final Map<String, String> queryParameters = <String, String>{};

    if (excludeUserId != null) {
      queryParameters['exclude_user_id'] = excludeUserId;
    }

    if (fromUserId != null) {
      queryParameters['from_user_id'] = fromUserId;
    }

    final Uri requestUri = _baseUri
        .resolve('/messages/unread-count')
        .replace(
          queryParameters: queryParameters.isEmpty ? null : queryParameters,
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

  Future<Map<String, int>> listUnreadMessageCounts() async {
    final http.Response response = await _client.get(
      _baseUri.resolve('/messages/unread-counts'),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      throw ChatApiException(
        _readErrorMessage(
          response,
          fallback:
              'Unread counts loading failed with status code '
              '${response.statusCode}.',
        ),
      );
    }

    final Object? decodedBody = jsonDecode(response.body);

    if (decodedBody is! Map) {
      throw const ChatApiException(
        'The server returned invalid unread counts.',
      );
    }

    final Object? rawCounts = decodedBody['counts_by_sender_id'];
    final Object? rawTotal = decodedBody['total_unread_count'];

    if (rawTotal is! int) {
      throw const ChatApiException(
        'The server returned invalid unread counts.',
      );
    }

    final Map<String, int>? counts = tryParseUnreadCounts(
      rawCounts,
      total: rawTotal,
    );
    if (counts == null) {
      throw const ChatApiException(
        'The server returned invalid unread counts.',
      );
    }

    return Map<String, int>.unmodifiable(counts);
  }

  Future<ChatMessage> retryMessageTranslation({
    required String messageId,
  }) async {
    final http.Response response = await _client.post(
      _baseUri.resolve('/messages/$messageId/translation/retry'),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      throw ChatApiException(
        _readErrorMessage(
          response,
          fallback:
              'Translation retry failed with status code '
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

  Future<ChatMessage> sendTextMessage({
    required String recipientId,
    required String content,
    String? replyToMessageId,
  }) async {
    final String? previewUrl = firstChatUrlInText(content);
    Map<String, Object?>? metadata;

    if (previewUrl != null) {
      metadata = <String, Object?>{
        'url': previewUrl,
        'domain': chatDomainForUrl(previewUrl),
      };
      final Uri? previewUri = Uri.tryParse(previewUrl);

      if (previewUri != null) {
        // 서버가 차단되는 사이트만 기기에서 미리 읽어 fallback 메타데이터로 보내요.
        final Map<String, Object?>? devicePreview =
            await DeviceLinkPreviewFetcher(client: _client).fetch(previewUri);

        if (devicePreview != null) {
          metadata.addAll(devicePreview);
        }
      }
    }

    return _createMessage(
      recipientId: recipientId,
      content: content,
      messageType: previewUrl == null ? 'text' : 'link',
      metadata: metadata,
      replyToMessageId: replyToMessageId,
    );
  }

  Future<ChatMessage> sendPhotoMessage({
    required String recipientId,
    required List<ChatPhotoAttachment> photos,
    String? replyToMessageId,
    ChatPhotoUploadProgressCallback? onUploadProgress,
  }) async {
    final Stopwatch totalStopwatch = Stopwatch()..start();
    final Stopwatch uploadsStopwatch = Stopwatch()..start();
    final List<String> mediaAssetIds = <String>[];

    for (int index = 0; index < photos.length; index += 1) {
      final ChatPhotoAttachment photo = photos[index];
      final String mediaAssetId =
          photo.mediaAssetId ??
          await _uploadMediaAsset(
            kind: 'photo',
            fileName: photo.fileName ?? '${photo.assetId}.jpg',
            mimeType: photo.mimeType ?? 'image/jpeg',
            sizeBytes: photo.sizeBytes ?? photo.uploadBytes?.length ?? 0,
            bytes: photo.uploadBytes,
            thumbnailBytes: photo.previewBytes,
            width: photo.width,
            height: photo.height,
            completeUpload: false,
            photoIndex: index + 1,
            photoCount: photos.length,
            onUploadProgress: (int uploadedBytes, int totalBytes) {
              onUploadProgress?.call(
                assetId: photo.assetId,
                uploadedBytes: uploadedBytes,
                totalBytes: totalBytes,
              );
            },
          );

      mediaAssetIds.add(mediaAssetId);
    }
    uploadsStopwatch.stop();
    _logPhotoSendTiming(
      'asset_uploads',
      uploadsStopwatch,
      photoCount: photos.length,
      originalBytes: photos.fold<int>(
        0,
        (int total, ChatPhotoAttachment photo) =>
            total + (photo.uploadBytes?.length ?? photo.sizeBytes ?? 0),
      ),
      previewBytes: photos.fold<int>(
        0,
        (int total, ChatPhotoAttachment photo) =>
            total + (photo.previewBytes?.length ?? 0),
      ),
    );

    final Stopwatch messageStopwatch = Stopwatch()..start();
    final ChatMessage message = await _createMessage(
      endpointPath: '/messages/photo',
      recipientId: recipientId,
      messageType: 'photo',
      replyToMessageId: replyToMessageId,
      metadata: <String, Object?>{'media_asset_ids': mediaAssetIds},
      onServerTiming: (String value) {
        recordPhotoSendDiagnostic(
          '[photo-send] stage=server_breakdown photo_count=${photos.length} '
          'timing=$value',
        );
      },
    );
    messageStopwatch.stop();
    _logPhotoSendTiming(
      'server_finalize',
      messageStopwatch,
      photoCount: photos.length,
    );

    final ChatMessage resolvedMessage = _withLocalPhotoPreviews(
      message,
      photos,
    );
    totalStopwatch.stop();
    _logPhotoSendTiming('api_total', totalStopwatch, photoCount: photos.length);
    return resolvedMessage;
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
    Uint8List? thumbnailBytes,
    int? width,
    int? height,
    Duration? duration,
    Map<String, Object?>? metadata,
    bool completeUpload = true,
    int? photoIndex,
    int? photoCount,
    void Function(int uploadedBytes, int totalBytes)? onUploadProgress,
  }) async {
    if (bytes == null || bytes.isEmpty) {
      throw const ChatApiException('The selected media file is empty.');
    }

    // 서버가 발급한 URL로 원본과 채팅용 미리보기를 함께 올려요.
    final Stopwatch preparationStopwatch = Stopwatch()..start();
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
    preparationStopwatch.stop();

    if (photoIndex != null && photoCount != null) {
      _logPhotoSendTiming(
        'upload_prepare',
        preparationStopwatch,
        photoCount: photoCount,
        photoIndex: photoIndex,
        originalBytes: bytes.length,
        previewBytes: thumbnailBytes?.length ?? 0,
      );
    }

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
    final String? thumbnailUploadUrl = _optionalString(
      decodedBody['thumbnail_upload_url'],
    );
    final Object? thumbnailUploadHeadersJson =
        decodedBody['thumbnail_upload_headers'];
    final Map<String, String> thumbnailUploadHeaders =
        thumbnailUploadHeadersJson is Map<String, dynamic>
        ? thumbnailUploadHeadersJson.map(
            (String key, dynamic value) =>
                MapEntry<String, String>(key, value.toString()),
          )
        : <String, String>{'Content-Type': 'image/jpeg'};

    final bool hasThumbnail =
        thumbnailUploadUrl != null &&
        thumbnailBytes != null &&
        thumbnailBytes.isNotEmpty;

    Future<http.Response> uploadOriginal() async {
      final Stopwatch stopwatch = Stopwatch()..start();
      final http.Response response = await _putMediaBytes(
        url: Uri.parse(uploadUrl),
        headers: uploadHeaders,
        bytes: bytes,
        onUploadProgress: onUploadProgress,
      );
      stopwatch.stop();

      if (photoIndex != null && photoCount != null) {
        _logPhotoSendTiming(
          'original_upload',
          stopwatch,
          photoCount: photoCount,
          photoIndex: photoIndex,
          originalBytes: bytes.length,
        );
      }

      return response;
    }

    Future<http.Response> uploadThumbnail() async {
      final Stopwatch stopwatch = Stopwatch()..start();
      final http.Response response = await _client.put(
        Uri.parse(thumbnailUploadUrl!),
        headers: thumbnailUploadHeaders,
        body: thumbnailBytes!,
      );
      stopwatch.stop();

      if (photoIndex != null && photoCount != null) {
        _logPhotoSendTiming(
          'preview_upload',
          stopwatch,
          photoCount: photoCount,
          photoIndex: photoIndex,
          previewBytes: thumbnailBytes!.length,
        );
      }

      return response;
    }

    final List<Future<http.Response>> uploadFutures = <Future<http.Response>>[
      uploadOriginal(),
      if (hasThumbnail) uploadThumbnail(),
    ];
    final List<http.Response> uploadResponses = await Future.wait(
      uploadFutures,
    );
    final http.Response uploadResponse = uploadResponses.first;

    if (uploadResponse.statusCode < 200 || uploadResponse.statusCode >= 300) {
      throw ChatApiException(
        'Media upload failed with status code '
        '${uploadResponse.statusCode}.',
      );
    }

    if (hasThumbnail) {
      final http.Response thumbnailUploadResponse = uploadResponses[1];

      if (thumbnailUploadResponse.statusCode < 200 ||
          thumbnailUploadResponse.statusCode >= 300) {
        throw ChatApiException(
          'Photo thumbnail upload failed with status code '
          '${thumbnailUploadResponse.statusCode}.',
        );
      }
    }

    if (completeUpload) {
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
    }

    return mediaAssetId;
  }

  Future<http.Response> _putMediaBytes({
    required Uri url,
    required Map<String, String> headers,
    required Uint8List bytes,
    void Function(int uploadedBytes, int totalBytes)? onUploadProgress,
  }) async {
    final http.StreamedRequest request = http.StreamedRequest('PUT', url)
      ..headers.addAll(headers)
      ..contentLength = bytes.length;
    final Future<http.StreamedResponse> responseFuture = _client.send(request);
    int uploadedBytes = 0;

    const int chunkSize = 64 * 1024;
    final Stream<List<int>> uploadStream =
        Stream<List<int>>.fromIterable(<Uint8List>[
          for (int offset = 0; offset < bytes.length; offset += chunkSize)
            Uint8List.sublistView(
              bytes,
              offset,
              offset + chunkSize < bytes.length
                  ? offset + chunkSize
                  : bytes.length,
            ),
        ]).map((List<int> chunk) {
          uploadedBytes += chunk.length;
          onUploadProgress?.call(uploadedBytes, bytes.length);
          return chunk;
        });

    await request.sink.addStream(uploadStream);
    await request.sink.close();

    return http.Response.fromStream(await responseFuture);
  }

  Future<Uri> createMediaAssetAccessUrl({required String mediaAssetId}) async {
    return _createMediaAssetAccessUrl(mediaAssetId: mediaAssetId);
  }

  Future<Uri> createMediaAssetThumbnailAccessUrl({
    required String mediaAssetId,
  }) async {
    return _createMediaAssetAccessUrl(
      mediaAssetId: mediaAssetId,
      variant: 'thumbnail',
    );
  }

  Future<Uri> _createMediaAssetAccessUrl({
    required String mediaAssetId,
    String? variant,
  }) async {
    final Uri accessUri = _baseUri.resolve(
      '/media-assets/$mediaAssetId/access',
    );
    final http.Response response = await _client.get(
      variant == null
          ? accessUri
          : accessUri.replace(
              queryParameters: <String, String>{'variant': variant},
            ),
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

    // 서버 응답에는 없는 기기 미리 보기를 합쳐 전송 직후에도 사진을 바로 보여 줘요.
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

    // 서버 메타데이터와 녹음 직후의 로컬 오디오를 합쳐 즉시 재생할 수 있게 해요.
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

  Future<ChatMessage> updateCallOutcome({
    required String messageId,
    required ChatCallOutcome outcome,
    required Duration duration,
  }) async {
    final http.Response response = await _client.patch(
      _baseUri.resolve('/messages/$messageId/call-outcome'),
      headers: _jsonHeaders,
      body: jsonEncode(<String, Object?>{
        'outcome': _callOutcomeToApi(outcome),
        'duration_ms': duration.inMilliseconds,
      }),
    );

    if (response.statusCode != 200) {
      throw ChatApiException(
        _readErrorMessage(
          response,
          fallback:
              'Call outcome update failed with status code '
              '${response.statusCode}.',
        ),
      );
    }

    final Object? decodedBody = jsonDecode(response.body);
    if (decodedBody is! Map<String, dynamic>) {
      throw const ChatApiException('The server returned an invalid call.');
    }

    return messageFromJson(decodedBody);
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
    String endpointPath = '/messages',
    required String recipientId,
    required String messageType,
    String content = '',
    Map<String, Object?>? metadata,
    String? replyToMessageId,
    void Function(String value)? onServerTiming,
  }) async {
    // 서버가 메시지 순서에 쓰는 시각을 기기에서 UTC로 고정해 전달해요.
    final Map<String, Object?> body = <String, Object?>{
      'recipient_id': recipientId,
      'content': content,
      'message_type': messageType,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'metadata': ?metadata,
      'reply_to_message_id': ?replyToMessageId,
    };

    final http.Response response = await _client.post(
      _baseUri.resolve(endpointPath),
      headers: _jsonHeaders,
      body: jsonEncode(body),
    );
    final String? serverTiming = response.headers['server-timing'];

    if (serverTiming != null && serverTiming.isNotEmpty) {
      onServerTiming?.call(serverTiming);
    }

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

  Map<String, Object?> messageToCacheJson(ChatMessage message) {
    final String messageType;
    final Map<String, Object?>? metadata;

    if (message.isPhotoMessage) {
      messageType = 'photo';
      metadata = <String, Object?>{
        'photos': message.photoAttachments
            .map(
              (ChatPhotoAttachment photo) => <String, Object?>{
                'asset_id': photo.assetId,
                'media_asset_id': photo.mediaAssetId ?? photo.assetId,
                'width': photo.width,
                'height': photo.height,
                'file_name': photo.fileName,
                'mime_type': photo.mimeType,
                'size_bytes': photo.sizeBytes,
              },
            )
            .toList(growable: false),
      };
    } else if (message.isFileMessage) {
      final ChatFileAttachment file = message.fileAttachment!;
      messageType = 'file';
      metadata = <String, Object?>{
        'file': <String, Object?>{
          'name': file.name,
          'media_asset_id': file.mediaAssetId,
          'mime_type': file.mimeType,
          'size_bytes': file.sizeBytes,
        },
      };
    } else if (message.isVoiceMemoMessage) {
      final ChatVoiceMemoAttachment voiceMemo = message.voiceMemoAttachment!;
      messageType = 'voice_memo';
      metadata = <String, Object?>{
        'duration_ms': voiceMemo.duration.inMilliseconds,
        'media_asset_id': voiceMemo.mediaAssetId,
        'mime_type': voiceMemo.mimeType,
        'file_name': voiceMemo.fileName,
        'size_bytes': voiceMemo.sizeBytes,
        'waveform_samples': voiceMemo.waveformSamples,
      };
    } else if (message.isCallMessage) {
      final ChatCallAttachment call = message.callAttachment!;
      messageType = 'call';
      metadata = <String, Object?>{
        'kind': _callKindToApi(call.kind),
        'outcome': _callOutcomeToApi(call.outcome),
        'duration_ms': call.duration.inMilliseconds,
      };
    } else if (message.isLinkMessage) {
      final ChatLinkPreview preview = message.linkPreview!;
      messageType = 'link';
      metadata = <String, Object?>{
        'url': preview.url,
        'canonical_url': preview.canonicalUrl,
        'domain': preview.domain,
        'title': preview.title,
        'description': preview.description,
        'site_name': preview.siteName,
        'image_url': preview.imageUrl,
      };
    } else {
      messageType = 'text';
      metadata = null;
    }

    final ChatReplyReference? replyTo = message.replyTo;

    return <String, Object?>{
      'id': message.id,
      'sender_id': message.senderId,
      'recipient_id': message.recipientId,
      'content': message.content,
      'message_type': messageType,
      'metadata': metadata,
      'reply_to_message_id': replyTo?.messageId,
      'reply_to': replyTo == null
          ? null
          : <String, Object?>{
              'message_id': replyTo.messageId,
              'sender_id': replyTo.senderId,
              'content': replyTo.content,
            },
      'created_at': message.createdAt.toUtc().toIso8601String(),
      'edited_at': message.editedAt?.toUtc().toIso8601String(),
      'read_at': message.readAt?.toUtc().toIso8601String(),
      'source_language': message.sourceLanguage,
      'translated_content': message.translatedContent,
      'translated_language': message.translatedLanguage,
      'translation_status': switch (message.translationStatus) {
        ChatTranslationStatus.none => 'none',
        ChatTranslationStatus.translating => 'pending',
        ChatTranslationStatus.translated => 'completed',
        ChatTranslationStatus.failed => 'failed',
      },
      'translation_provider': null,
      'translation_model': null,
    };
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
        _optionalString(metadataUrl) ?? firstChatUrlInText(content);

    if (url == null) {
      return null;
    }

    final String? canonicalUrl = _optionalString(metadataCanonicalUrl);
    final String domain =
        _optionalString(metadataDomain) ??
        chatDomainForUrl(canonicalUrl ?? url);

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
      'none' => ChatTranslationStatus.none,
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

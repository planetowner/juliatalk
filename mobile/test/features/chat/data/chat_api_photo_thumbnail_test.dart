import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juliatalk/features/chat/data/chat_api.dart';
import 'package:juliatalk/features/chat/domain/chat_message.dart';

const MethodChannel _pathProviderChannel = MethodChannel(
  'plugins.flutter.io/path_provider',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('requests the chat thumbnail variant', () async {
    final MockClient client = MockClient((http.Request request) async {
      expect(request.method, 'GET');
      expect(
        request.url,
        Uri.parse(
          'https://api.example.com/media-assets/photo-1/access'
          '?variant=thumbnail',
        ),
      );

      return http.Response(
        jsonEncode(<String, Object?>{
          'media_asset_id': 'photo-1',
          'access_url': 'https://storage.example.com/chat.jpg',
          'expires_in_seconds': 900,
          'mime_type': 'image/jpeg',
          'file_name': 'photo.jpg',
          'size_bytes': 3,
        }),
        200,
        request: request,
      );
    });
    final ChatApi chatApi = ChatApi(
      client: client,
      baseUri: Uri.parse('https://api.example.com'),
      accessToken: 'test-token',
    );

    final Uri accessUrl = await chatApi.createMediaAssetThumbnailAccessUrl(
      mediaAssetId: 'photo-1',
    );

    expect(accessUrl, Uri.parse('https://storage.example.com/chat.jpg'));
  });

  test(
    'uploads the original and thumbnail before one photo message request',
    () async {
      final Uint8List originalBytes = Uint8List(65537);
      final Uint8List thumbnailBytes = Uint8List.fromList(<int>[4, 5]);
      final DateTime createdAt = DateTime.utc(2026, 8, 16, 3, 59, 58);
      final List<Uri> requestedUrls = <Uri>[];
      final List<(String, int, int)> uploadProgress = <(String, int, int)>[];
      final Completer<void> thumbnailUploadStarted = Completer<void>();
      final MockClient client = MockClient((http.Request request) async {
        requestedUrls.add(request.url);

        if (request.url == Uri.parse('https://api.example.com/media-assets')) {
          expect(request.method, 'POST');

          return http.Response(
            jsonEncode(<String, Object?>{
              'media_asset_id': 'photo-1',
              'storage_key': 'original/photo.jpg',
              'upload_url': 'https://storage.example.com/original',
              'upload_headers': <String, String>{'Content-Type': 'image/jpeg'},
              'thumbnail_upload_url': 'https://storage.example.com/thumbnail',
              'thumbnail_upload_headers': <String, String>{
                'Content-Type': 'image/jpeg',
              },
              'expires_in_seconds': 900,
            }),
            201,
            request: request,
          );
        }

        if (request.url == Uri.parse('https://storage.example.com/original')) {
          expect(request.method, 'PUT');
          expect(request.bodyBytes, originalBytes);
          await thumbnailUploadStarted.future.timeout(
            const Duration(seconds: 5),
          );
          return http.Response('', 200, request: request);
        }

        if (request.url == Uri.parse('https://storage.example.com/thumbnail')) {
          expect(request.method, 'PUT');
          expect(request.bodyBytes, thumbnailBytes);
          thumbnailUploadStarted.complete();
          return http.Response('', 200, request: request);
        }

        expect(
          request.url,
          Uri.parse('https://api.example.com/messages/photo'),
        );
        expect(request.method, 'POST');
        expect(
          jsonDecode(request.body),
          containsPair('metadata', <String, Object?>{
            'media_asset_ids': <String>['photo-1'],
          }),
        );
        expect(
          jsonDecode(request.body),
          containsPair('created_at', createdAt.toIso8601String()),
        );

        return http.Response(
          jsonEncode(<String, Object?>{
            'id': 'message-1',
            'sender_id': 'current-user',
            'recipient_id': 'other-user',
            'content': '',
            'message_type': 'photo',
            'metadata': <String, Object?>{
              'photos': <Map<String, Object?>>[
                <String, Object?>{
                  'media_asset_id': 'photo-1',
                  'asset_id': 'photo-1',
                  'width': 1200,
                  'height': 900,
                  'file_name': 'photo.jpg',
                  'mime_type': 'image/jpeg',
                  'size_bytes': originalBytes.length,
                },
              ],
            },
            'created_at': '2026-08-16T04:00:00Z',
            'edited_at': null,
            'read_at': null,
            'translation_status': 'none',
            'translated_content': null,
            'source_language': null,
            'translated_language': null,
            'reply_to': null,
          }),
          201,
          request: request,
        );
      });
      final ChatApi chatApi = ChatApi(
        client: client,
        baseUri: Uri.parse('https://api.example.com'),
        accessToken: 'test-token',
      );

      await chatApi.sendPhotoMessage(
        recipientId: 'other-user',
        createdAt: createdAt,
        photos: <ChatPhotoAttachment>[
          ChatPhotoAttachment(
            assetId: 'local-photo',
            width: 1200,
            height: 900,
            previewBytes: thumbnailBytes,
            fileName: 'photo.jpg',
            mimeType: 'image/jpeg',
            sizeBytes: originalBytes.length,
            uploadBytes: originalBytes,
          ),
        ],
        onUploadProgress:
            ({
              required String assetId,
              required int uploadedBytes,
              required int totalBytes,
            }) {
              uploadProgress.add((assetId, uploadedBytes, totalBytes));
            },
      );

      expect(
        requestedUrls.first,
        Uri.parse('https://api.example.com/media-assets'),
      );
      expect(requestedUrls.sublist(1, 3).toSet(), <Uri>{
        Uri.parse('https://storage.example.com/original'),
        Uri.parse('https://storage.example.com/thumbnail'),
      });
      expect(requestedUrls.sublist(3), <Uri>[
        Uri.parse('https://api.example.com/messages/photo'),
      ]);
      expect(uploadProgress, <(String, int, int)>[
        ('local-photo', 65536, originalBytes.length),
        ('local-photo', originalBytes.length, originalBytes.length),
      ]);
    },
  );

  test(
    'uploads a video thumbnail and preserves the local playback source',
    () async {
      final Uint8List originalBytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final Uint8List thumbnailBytes = Uint8List.fromList(<int>[5, 6]);
      final DateTime createdAt = DateTime.utc(2026, 8, 17, 6, 29, 58);
      final Directory temporaryDirectory = await Directory.systemTemp
          .createTemp('juliatalk-video-upload-test-');
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      final Directory cacheDirectory = Directory(
        '${temporaryDirectory.path}/cache',
      );
      await cacheDirectory.create();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_pathProviderChannel, (
            MethodCall call,
          ) async {
            if (call.method == 'getApplicationCacheDirectory') {
              return cacheDirectory.path;
            }

            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_pathProviderChannel, null);
      });
      final Directory videoUploadDirectory = Directory(
        '${cacheDirectory.path}/video-uploads',
      );
      await videoUploadDirectory.create();
      final File encodedVideo = File(
        '${videoUploadDirectory.path}/encoded-video.mp4',
      );
      await encodedVideo.writeAsBytes(originalBytes);
      final List<Uri> requestedUrls = <Uri>[];
      final MockClient client = MockClient((http.Request request) async {
        requestedUrls.add(request.url);

        if (request.url == Uri.parse('https://api.example.com/media-assets')) {
          final Map<String, dynamic> body =
              jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['kind'], 'video');
          expect(body['duration_ms'], 14000);

          return http.Response(
            jsonEncode(<String, Object?>{
              'media_asset_id': 'video-1',
              'storage_key': 'original/video.mov',
              'upload_url': 'https://storage.example.com/video-original',
              'upload_headers': <String, String>{
                'Content-Type': 'video/quicktime',
              },
              'thumbnail_upload_url':
                  'https://storage.example.com/video-thumbnail',
              'thumbnail_upload_headers': <String, String>{
                'Content-Type': 'image/jpeg',
              },
              'expires_in_seconds': 900,
            }),
            201,
            request: request,
          );
        }

        if (request.url.host == 'storage.example.com') {
          expect(request.method, 'PUT');
          if (request.url.path == '/video-original') {
            expect(request.bodyBytes, originalBytes);
          }
          return http.Response('', 200, request: request);
        }

        expect(
          request.url,
          Uri.parse('https://api.example.com/messages/video'),
        );
        expect(request.method, 'POST');
        expect(
          jsonDecode(request.body),
          containsPair('created_at', createdAt.toIso8601String()),
        );
        expect(await encodedVideo.exists(), isFalse);
        expect(
          await File(
            '${cacheDirectory.path}/chat-videos/video-1.mov',
          ).readAsBytes(),
          originalBytes,
        );

        return http.Response(
          jsonEncode(<String, Object?>{
            'id': 'message-video-1',
            'sender_id': 'current-user',
            'recipient_id': 'other-user',
            'content': '',
            'message_type': 'video',
            'metadata': <String, Object?>{
              'video': <String, Object?>{
                'media_asset_id': 'video-1',
                'width': 1080,
                'height': 1920,
                'duration_ms': 14000,
                'file_name': 'video.mov',
                'mime_type': 'video/quicktime',
                'size_bytes': originalBytes.length,
              },
            },
            'created_at': '2026-08-17T06:30:00Z',
            'edited_at': null,
            'read_at': null,
            'translation_status': 'none',
            'translated_content': null,
            'source_language': null,
            'translated_language': null,
            'reply_to': null,
          }),
          201,
          request: request,
        );
      });
      final ChatApi chatApi = ChatApi(
        client: client,
        baseUri: Uri.parse('https://api.example.com'),
        accessToken: 'test-token',
      );

      final ChatMessage message = await chatApi.sendVideoMessage(
        recipientId: 'other-user',
        createdAt: createdAt,
        video: ChatVideoAttachment(
          assetId: 'local-video',
          width: 1080,
          height: 1920,
          duration: const Duration(seconds: 14),
          previewBytes: thumbnailBytes,
          fileName: 'video.mov',
          mimeType: 'video/quicktime',
          sizeBytes: originalBytes.length,
          localPath: encodedVideo.path,
        ),
      );

      expect(
        requestedUrls.first,
        Uri.parse('https://api.example.com/media-assets'),
      );
      expect(requestedUrls.sublist(1, 3).toSet(), <Uri>{
        Uri.parse('https://storage.example.com/video-original'),
        Uri.parse('https://storage.example.com/video-thumbnail'),
      });
      expect(
        requestedUrls[3],
        Uri.parse('https://api.example.com/messages/video'),
      );
      expect(message.videoAttachment?.previewBytes, thumbnailBytes);
      expect(
        message.videoAttachment?.localPath,
        '${cacheDirectory.path}/chat-videos/video-1.mov',
      );
      expect(
        await File(message.videoAttachment!.localPath!).readAsBytes(),
        originalBytes,
      );
      expect(await encodedVideo.exists(), isFalse);
      expect(message.videoAttachment?.duration, const Duration(seconds: 14));
    },
  );

  test(
    'uploads at most three photos concurrently and preserves order',
    () async {
      final List<Completer<void>> uploadStarted =
          List<Completer<void>>.generate(4, (_) => Completer<void>());
      final List<Completer<void>> releaseUpload =
          List<Completer<void>>.generate(4, (_) => Completer<void>());
      int activeUploads = 0;
      int maxActiveUploads = 0;
      List<String>? requestedMediaAssetIds;

      final MockClient client = MockClient((http.Request request) async {
        if (request.url == Uri.parse('https://api.example.com/media-assets')) {
          final Map<String, dynamic> body =
              jsonDecode(request.body) as Map<String, dynamic>;
          final String fileName = body['file_name'] as String;
          final int photoNumber = <String, int>{
            'photo-1.jpg': 1,
            'photo-2.jpg': 2,
            'photo-3.jpg': 3,
            'photo-4.jpg': 4,
          }[fileName]!;

          return http.Response(
            jsonEncode(<String, Object?>{
              'media_asset_id': 'photo-$photoNumber',
              'storage_key': 'original/photo-$photoNumber.jpg',
              'upload_url': 'https://storage.example.com/$photoNumber',
              'upload_headers': <String, String>{'Content-Type': 'image/jpeg'},
              'expires_in_seconds': 900,
            }),
            201,
            request: request,
          );
        }

        if (request.url.host == 'storage.example.com') {
          final int photoIndex = int.parse(request.url.pathSegments.single) - 1;
          activeUploads += 1;
          if (activeUploads > maxActiveUploads) {
            maxActiveUploads = activeUploads;
          }
          uploadStarted[photoIndex].complete();
          await releaseUpload[photoIndex].future.timeout(
            const Duration(seconds: 5),
          );
          activeUploads -= 1;
          return http.Response('', 200, request: request);
        }

        expect(
          request.url,
          Uri.parse('https://api.example.com/messages/photo'),
        );
        final Map<String, dynamic> body =
            jsonDecode(request.body) as Map<String, dynamic>;
        final Map<String, dynamic> metadata =
            body['metadata'] as Map<String, dynamic>;
        requestedMediaAssetIds = List<String>.from(
          metadata['media_asset_ids'] as List<dynamic>,
        );

        return http.Response(
          jsonEncode(<String, Object?>{
            'id': 'message-1',
            'sender_id': 'current-user',
            'recipient_id': 'other-user',
            'content': '',
            'message_type': 'photo',
            'metadata': <String, Object?>{
              'photos': List<Map<String, Object?>>.generate(
                4,
                (int index) => <String, Object?>{
                  'media_asset_id': 'photo-${index + 1}',
                  'asset_id': 'photo-${index + 1}',
                  'width': 1200,
                  'height': 900,
                  'file_name': 'photo-${index + 1}.jpg',
                  'mime_type': 'image/jpeg',
                  'size_bytes': index + 1,
                },
              ),
            },
            'created_at': '2026-08-16T04:00:00Z',
            'edited_at': null,
            'read_at': null,
            'translation_status': 'none',
            'translated_content': null,
            'source_language': null,
            'translated_language': null,
            'reply_to': null,
          }),
          201,
          request: request,
        );
      });
      final ChatApi chatApi = ChatApi(
        client: client,
        baseUri: Uri.parse('https://api.example.com'),
        accessToken: 'test-token',
      );
      final Future<ChatMessage> sendFuture = chatApi.sendPhotoMessage(
        recipientId: 'other-user',
        photos: List<ChatPhotoAttachment>.generate(
          4,
          (int index) => ChatPhotoAttachment(
            assetId: 'local-photo-${index + 1}',
            width: 1200,
            height: 900,
            fileName: 'photo-${index + 1}.jpg',
            mimeType: 'image/jpeg',
            sizeBytes: index + 1,
            uploadBytes: Uint8List(index + 1),
          ),
        ),
      );

      await Future.wait<void>(<Future<void>>[
        uploadStarted[0].future,
        uploadStarted[1].future,
        uploadStarted[2].future,
      ]).timeout(const Duration(seconds: 5));
      expect(uploadStarted[3].isCompleted, isFalse);
      expect(maxActiveUploads, 3);

      releaseUpload[0].complete();
      await uploadStarted[3].future.timeout(const Duration(seconds: 5));
      expect(maxActiveUploads, 3);

      releaseUpload[1].complete();
      releaseUpload[2].complete();
      releaseUpload[3].complete();
      await sendFuture.timeout(const Duration(seconds: 5));

      expect(activeUploads, 0);
      expect(requestedMediaAssetIds, <String>[
        'photo-1',
        'photo-2',
        'photo-3',
        'photo-4',
      ]);
    },
  );
}

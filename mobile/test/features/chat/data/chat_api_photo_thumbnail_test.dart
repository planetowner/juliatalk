import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juliatalk/features/chat/data/chat_api.dart';
import 'package:juliatalk/features/chat/domain/chat_message.dart';

void main() {
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
    'uploads the original and chat thumbnail together before completion',
    () async {
      final Uint8List originalBytes = Uint8List(65537);
      final Uint8List thumbnailBytes = Uint8List.fromList(<int>[4, 5]);
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

        if (request.url ==
            Uri.parse(
              'https://api.example.com/media-assets/photo-1/complete',
            )) {
          expect(request.method, 'POST');
          return http.Response(
            jsonEncode(<String, Object?>{
              'media_asset_id': 'photo-1',
              'upload_status': 'complete',
            }),
            200,
            request: request,
          );
        }

        expect(request.url, Uri.parse('https://api.example.com/messages'));
        expect(request.method, 'POST');

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
        Uri.parse('https://api.example.com/media-assets/photo-1/complete'),
        Uri.parse('https://api.example.com/messages'),
      ]);
      expect(uploadProgress, <(String, int, int)>[
        ('local-photo', 65536, originalBytes.length),
        ('local-photo', originalBytes.length, originalBytes.length),
      ]);
    },
  );
}

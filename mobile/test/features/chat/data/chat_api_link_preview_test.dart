import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juliatalk/features/chat/data/chat_api.dart';
import 'package:juliatalk/features/chat/domain/chat_message.dart';

const String _fmkoreaUrl = 'https://m.fmkorea.com/10166678809';
const String _fmkoreaCanonicalUrl = 'https://www.fmkorea.com/10166678809';
const String _fmkoreaImageUrl = 'https://image.fmkorea.com/files/preview.jpg';

http.Response _createdMessageResponse(
  http.Request request,
  Map<String, dynamic> requestBody,
) {
  return http.Response(
    jsonEncode(<String, Object?>{
      'id': 'message-1',
      'sender_id': 'current-user',
      'recipient_id': requestBody['recipient_id'],
      'content': requestBody['content'],
      'message_type': requestBody['message_type'],
      'metadata': requestBody['metadata'],
      'created_at': '2026-08-03T10:00:00Z',
      'edited_at': null,
      'read_at': null,
      'translation_status': 'none',
      'translated_content': null,
      'source_language': null,
      'translated_language': null,
      'reply_to': null,
    }),
    201,
    headers: const <String, String>{'content-type': 'application/json'},
    request: request,
  );
}

void main() {
  test(
    'sends device-fetched FMKorea Open Graph metadata to the server',
    () async {
      var requestCount = 0;
      late Map<String, dynamic> sentMetadata;
      final MockClient client = MockClient((http.Request request) async {
        requestCount += 1;

        if (request.url.host == 'm.fmkorea.com') {
          expect(request.method, 'GET');
          expect(
            request.headers['User-Agent'],
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 '
            'Safari/605.1.15',
          );
          expect(request.headers['Accept'], 'text/html,application/xhtml+xml');
          expect(request.headers['Accept-Language'], 'ko-KR,ko;q=0.9');

          return http.Response(
            '<html><head>'
            '<meta property="og:url" content="$_fmkoreaCanonicalUrl">'
            '<meta property="og:title" content="우리는 모르는 잘생긴 남자의 삶">'
            '<meta property="og:description" '
            'content="Tap here to open the link.">'
            '<meta property="og:image" content="$_fmkoreaImageUrl">'
            '<meta property="og:site_name" content="에펨코리아">'
            '</head><body></body></html>',
            200,
            headers: const <String, String>{
              'content-type': 'text/html; charset=UTF-8',
            },
            request: request,
          );
        }

        expect(request.method, 'POST');
        expect(request.url, Uri.parse('https://api.example.com/messages'));
        final Map<String, dynamic> requestBody =
            jsonDecode(request.body) as Map<String, dynamic>;
        sentMetadata = requestBody['metadata'] as Map<String, dynamic>;

        return _createdMessageResponse(request, requestBody);
      });
      final ChatApi chatApi = ChatApi(
        client: client,
        baseUri: Uri.parse('https://api.example.com'),
        accessToken: 'test-token',
      );

      final ChatMessage message = await chatApi.sendTextMessage(
        recipientId: 'other-user',
        content: _fmkoreaUrl,
      );

      expect(requestCount, 2);
      expect(sentMetadata, <String, dynamic>{
        'url': _fmkoreaUrl,
        'canonical_url': _fmkoreaCanonicalUrl,
        'domain': 'm.fmkorea.com',
        'title': '우리는 모르는 잘생긴 남자의 삶',
        'description': 'Tap here to open the link.',
        'site_name': '에펨코리아',
        'image_url': _fmkoreaImageUrl,
      });
      expect(message.linkPreview?.title, '우리는 모르는 잘생긴 남자의 삶');
      expect(message.linkPreview?.imageUrl, _fmkoreaImageUrl);
    },
  );

  test(
    'still sends an FMKorea link when device fetching is rejected',
    () async {
      var requestCount = 0;
      final MockClient client = MockClient((http.Request request) async {
        requestCount += 1;

        if (request.url.host == 'm.fmkorea.com') {
          return http.Response('Too Many Requests', 429, request: request);
        }

        final Map<String, dynamic> requestBody =
            jsonDecode(request.body) as Map<String, dynamic>;

        return _createdMessageResponse(request, requestBody);
      });
      final ChatApi chatApi = ChatApi(
        client: client,
        baseUri: Uri.parse('https://api.example.com'),
        accessToken: 'test-token',
      );

      final ChatMessage message = await chatApi.sendTextMessage(
        recipientId: 'other-user',
        content: _fmkoreaUrl,
      );

      expect(requestCount, 2);
      expect(message.linkPreview?.domain, 'm.fmkorea.com');
      expect(message.linkPreview?.title, isNull);
    },
  );

  test('does not device-fetch domains handled by the server', () async {
    var requestCount = 0;
    final MockClient client = MockClient((http.Request request) async {
      requestCount += 1;
      expect(request.url, Uri.parse('https://api.example.com/messages'));
      final Map<String, dynamic> requestBody =
          jsonDecode(request.body) as Map<String, dynamic>;

      return _createdMessageResponse(request, requestBody);
    });
    final ChatApi chatApi = ChatApi(
      client: client,
      baseUri: Uri.parse('https://api.example.com'),
      accessToken: 'test-token',
    );

    await chatApi.sendTextMessage(
      recipientId: 'other-user',
      content: 'https://youtu.be/CS0zz7WlnV0',
    );

    expect(requestCount, 1);
  });
}

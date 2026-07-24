import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juliatalk/features/chat/data/chat_api.dart';

void main() {
  test('requests the page before the supplied message cursor', () async {
    final MockClient client = MockClient((http.Request request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/messages/conversation/other-user');
      expect(request.url.queryParameters, <String, String>{
        'limit': '100',
        'before_message_id': 'message-101',
      });

      return http.Response(
        '[]',
        200,
        headers: const <String, String>{
          'content-type': 'application/json',
          'x-has-more': 'true',
        },
      );
    });
    final ChatApi chatApi = ChatApi(
      client: client,
      baseUri: Uri.parse('https://api.example.com'),
      accessToken: 'test-token',
    );

    final ChatConversationPage page = await chatApi.listConversation(
      otherUserId: 'other-user',
      beforeMessageId: 'message-101',
    );

    expect(page.messages, isEmpty);
    expect(page.hasMore, isTrue);
  });

  test('uses the server pagination completion header', () async {
    final MockClient client = MockClient((http.Request request) async {
      return http.Response(
        '[]',
        200,
        headers: const <String, String>{
          'content-type': 'application/json',
          'x-has-more': 'false',
        },
      );
    });
    final ChatApi chatApi = ChatApi(
      client: client,
      baseUri: Uri.parse('https://api.example.com'),
      accessToken: 'test-token',
    );

    final ChatConversationPage page = await chatApi.listConversation(
      otherUserId: 'other-user',
    );

    expect(page.hasMore, isFalse);
  });
}

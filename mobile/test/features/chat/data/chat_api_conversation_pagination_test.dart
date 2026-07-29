import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juliatalk/features/chat/data/chat_api.dart';
import 'package:juliatalk/features/chat/data/chat_api_exception.dart';

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

  test('requests the page after the supplied message cursor', () async {
    final MockClient client = MockClient((http.Request request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/messages/conversation/other-user');
      expect(request.url.queryParameters, <String, String>{
        'limit': '100',
        'after_message_id': 'message-101',
      });

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
      afterMessageId: 'message-101',
    );

    expect(page.messages, isEmpty);
    expect(page.hasMore, isFalse);
  });

  test('requests a small message-centered conversation context', () async {
    final MockClient client = MockClient((http.Request request) async {
      expect(request.method, 'GET');
      expect(
        request.url.path,
        '/messages/conversation/other-user/around/message-101',
      );
      expect(request.url.queryParameters, <String, String>{
        'older_limit': '20',
        'newer_limit': '25',
      });

      return http.Response(
        '{"messages":[],"has_more_older":true,"has_more_newer":false}',
        200,
        headers: const <String, String>{'content-type': 'application/json'},
      );
    });
    final ChatApi chatApi = ChatApi(
      client: client,
      baseUri: Uri.parse('https://api.example.com'),
      accessToken: 'test-token',
    );

    final ChatConversationContext context = await chatApi
        .getConversationMessageContext(
          otherUserId: 'other-user',
          messageId: 'message-101',
          olderLimit: 20,
          newerLimit: 25,
        );

    expect(context.messages, isEmpty);
    expect(context.hasMoreOlder, isTrue);
    expect(context.hasMoreNewer, isFalse);
  });

  test('marks only transient conversation failures as retryable', () async {
    final List<int> statusCodes = <int>[503, 401];
    final MockClient client = MockClient((http.Request request) async {
      return http.Response('{}', statusCodes.removeAt(0));
    });
    final ChatApi chatApi = ChatApi(
      client: client,
      baseUri: Uri.parse('https://api.example.com'),
      accessToken: 'test-token',
    );

    await expectLater(
      chatApi.listConversation(otherUserId: 'other-user'),
      throwsA(
        isA<ChatApiException>()
            .having(
              (ChatApiException error) => error.retryable,
              'retryable',
              isTrue,
            )
            .having(
              (ChatApiException error) => error.statusCode,
              'statusCode',
              503,
            ),
      ),
    );
    await expectLater(
      chatApi.listConversation(otherUserId: 'other-user'),
      throwsA(
        isA<ChatApiException>()
            .having(
              (ChatApiException error) => error.retryable,
              'retryable',
              isFalse,
            )
            .having(
              (ChatApiException error) => error.statusCode,
              'statusCode',
              401,
            ),
      ),
    );
  });
}

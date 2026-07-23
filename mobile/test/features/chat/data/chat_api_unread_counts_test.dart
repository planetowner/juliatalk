import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juliatalk/features/chat/data/chat_api.dart';
import 'package:juliatalk/features/chat/data/chat_api_exception.dart';

void main() {
  test('loads all unread counts from one authoritative response', () async {
    final MockClient client = MockClient((http.Request request) async {
      expect(request.method, 'GET');
      expect(
        request.url,
        Uri.parse('https://api.example.com/messages/unread-counts'),
      );
      expect(request.headers['Authorization'], 'Bearer test-token');

      return http.Response(
        jsonEncode(<String, dynamic>{
          'counts_by_sender_id': <String, int>{'lia': 2, 'yun': 3},
          'total_unread_count': 5,
        }),
        200,
        headers: const <String, String>{'content-type': 'application/json'},
      );
    });
    final ChatApi chatApi = ChatApi(
      client: client,
      baseUri: Uri.parse('https://api.example.com'),
      accessToken: 'test-token',
    );

    expect(await chatApi.listUnreadMessageCounts(), <String, int>{
      'lia': 2,
      'yun': 3,
    });
  });

  test('rejects an unread total that disagrees with sender counts', () async {
    final MockClient client = MockClient((http.Request request) async {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'counts_by_sender_id': <String, int>{'lia': 2},
          'total_unread_count': 3,
        }),
        200,
        headers: const <String, String>{'content-type': 'application/json'},
      );
    });
    final ChatApi chatApi = ChatApi(
      client: client,
      baseUri: Uri.parse('https://api.example.com'),
      accessToken: 'test-token',
    );

    expect(
      () => chatApi.listUnreadMessageCounts(),
      throwsA(isA<ChatApiException>()),
    );
  });
}

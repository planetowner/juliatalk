import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juliatalk/features/auth/domain/app_user.dart';
import 'package:juliatalk/features/chat/data/chat_api.dart';

void main() {
  test(
    'uses the viewer-specific display name returned by the server',
    () async {
      final MockClient client = MockClient((http.Request request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/users');

        return http.Response(
          jsonEncode(<Map<String, dynamic>>[
            <String, dynamic>{
              'id': '11111111-1111-4111-8111-111111111111',
              'username': 'junebabo',
              'display_name': 'Lia',
              'viewer_display_name': '애기🤍',
              'profile_image_url': null,
              'preferred_language': 'ko',
            },
          ]),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      });
      final ChatApi chatApi = ChatApi(
        client: client,
        baseUri: Uri.parse('https://api.example.com'),
        accessToken: 'test-token',
      );

      final List<AppUser> users = await chatApi.listUsers();

      expect(users.single.displayName, 'Lia');
      expect(users.single.viewerDisplayName, '애기🤍');
      expect(users.single.effectiveDisplayName, '애기🤍');
    },
  );

  test('falls back to the global display name for older responses', () async {
    const AppUser user = AppUser(
      id: '11111111-1111-4111-8111-111111111111',
      username: 'unknown-user',
      displayName: 'Server Name',
      preferredLanguage: 'ko',
    );

    expect(user.effectiveDisplayName, 'Server Name');
  });
}

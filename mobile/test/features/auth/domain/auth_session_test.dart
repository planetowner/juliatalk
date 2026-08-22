import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/features/auth/domain/app_user.dart';
import 'package:juliatalk/features/auth/domain/auth_session.dart';

void main() {
  const AppUser user = AppUser(
    id: '11111111-1111-4111-8111-111111111111',
    username: 'test-user',
    displayName: 'June',
    preferredLanguage: 'ko',
  );

  test('reads the access token expiration from its JWT payload', () {
    final int expirationSeconds =
        DateTime.utc(2030, 1, 2, 3, 4, 5).millisecondsSinceEpoch ~/
        Duration.millisecondsPerSecond;
    final String payload = base64Url.encode(
      utf8.encode(jsonEncode({'exp': expirationSeconds})),
    );
    final AuthSession session = AuthSession(
      accessToken: 'header.$payload.signature',
      refreshToken: 'refresh-token',
      tokenType: 'bearer',
      user: user,
    );

    expect(session.accessTokenExpiresAt, DateTime.utc(2030, 1, 2, 3, 4, 5));
  });

  test('returns null when the access token has no readable expiration', () {
    const AuthSession session = AuthSession(
      accessToken: 'not-a-jwt',
      refreshToken: 'refresh-token',
      tokenType: 'bearer',
      user: user,
    );

    expect(session.accessTokenExpiresAt, isNull);
  });
}

import 'dart:convert';

import 'app_user.dart';

final class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.tokenType,
    required this.user,
  });

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    return AuthSession(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String,
      tokenType: json['token_type'] as String,
      user: AppUser.fromJson(json['user'] as Map<String, dynamic>),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'token_type': tokenType,
      'user': user.toJson(),
    };
  }

  final String accessToken;
  final String refreshToken;
  final String tokenType;
  final AppUser user;

  DateTime? get accessTokenExpiresAt {
    try {
      final List<String> tokenParts = accessToken.split('.');
      if (tokenParts.length != 3) {
        return null;
      }

      final Object? decodedPayload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(tokenParts[1]))),
      );
      if (decodedPayload is! Map<String, dynamic>) {
        return null;
      }

      final Object? expiration = decodedPayload['exp'];
      if (expiration is! num) {
        return null;
      }

      return DateTime.fromMillisecondsSinceEpoch(
        expiration.toInt() * Duration.millisecondsPerSecond,
        isUtc: true,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}

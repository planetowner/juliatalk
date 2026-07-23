import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/auth_session.dart';

final class AuthSessionStore {
  const AuthSessionStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;

  static const String _sessionKey = 'juliatalk.auth_session.v1';

  final FlutterSecureStorage _storage;

  Future<AuthSession?> load() async {
    final String? encodedSession = await _storage.read(key: _sessionKey);

    if (encodedSession == null || encodedSession.isEmpty) {
      return null;
    }

    try {
      final Object? decodedSession = jsonDecode(encodedSession);

      if (decodedSession is! Map<String, dynamic>) {
        await clear();
        return null;
      }

      return AuthSession.fromJson(decodedSession);
    } on FormatException {
      await clear();
      return null;
    } on TypeError {
      await clear();
      return null;
    }
  }

  Future<void> save(AuthSession session) {
    return _storage.write(
      key: _sessionKey,
      value: jsonEncode(session.toJson()),
    );
  }

  Future<void> clear() {
    return _storage.delete(key: _sessionKey);
  }
}

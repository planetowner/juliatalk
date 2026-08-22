import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/auth_session.dart';
import 'auth_login_exception.dart';
import 'auth_refresh_exception.dart';

final class AuthApi {
  const AuthApi({required http.Client client, required Uri baseUri})
    : _client = client,
      _baseUri = baseUri;

  final http.Client _client;
  final Uri _baseUri;

  Future<AuthSession> login({
    required String username,
    required String password,
  }) async {
    final http.Response response = await _client.post(
      _baseUri.resolve('/auth/login'),
      headers: const {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'username': username, 'password': password}),
    );

    final Map<String, dynamic> responseJson =
        jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode == 200) {
      return AuthSession.fromJson(responseJson);
    }

    if (response.statusCode == 401) {
      throw AuthLoginException(responseJson['detail'] as String);
    }

    throw AuthLoginException(
      'Login failed with status code ${response.statusCode}.',
    );
  }

  Future<AuthSession> refresh({required String refreshToken}) async {
    final http.Response response = await _client.post(
      _baseUri.resolve('/auth/refresh'),
      headers: const {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'refresh_token': refreshToken}),
    );

    final Object? decodedBody = jsonDecode(response.body);
    if (response.statusCode == 200 && decodedBody is Map<String, dynamic>) {
      return AuthSession.fromJson(decodedBody);
    }

    final String message = decodedBody is Map<String, dynamic>
        ? decodedBody['detail'] as String? ?? 'Session refresh failed.'
        : 'Session refresh failed.';

    throw AuthRefreshException(message, statusCode: response.statusCode);
  }
}

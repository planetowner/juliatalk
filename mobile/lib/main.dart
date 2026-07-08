import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'core/config/app_config.dart';
import 'design_system/app_theme.dart';
import 'features/auth/data/auth_api.dart';
import 'features/auth/domain/auth_session.dart';
import 'features/auth/presentation/login_screen.dart';
import 'features/chat/presentation/chat_conversation_screen.dart';

void main() {
  final AppConfig appConfig = AppConfig.fromEnvironment();

  runApp(JuliaTalkApp(appConfig: appConfig));
}

final class JuliaTalkApp extends StatefulWidget {
  const JuliaTalkApp({required this.appConfig, super.key});

  final AppConfig appConfig;

  @override
  State<JuliaTalkApp> createState() {
    return _JuliaTalkAppState();
  }
}

final class _JuliaTalkAppState extends State<JuliaTalkApp> {
  late final http.Client _httpClient;
  late final AuthApi _authApi;

  AuthSession? _session;

  @override
  void initState() {
    super.initState();

    _httpClient = http.Client();

    _authApi = AuthApi(
      client: _httpClient,
      baseUri: widget.appConfig.apiBaseUri,
    );
  }

  @override
  void dispose() {
    _httpClient.close();
    super.dispose();
  }

  Future<void> _login({
    required String username,
    required String password,
  }) async {
    final AuthSession session = await _authApi.login(
      username: username,
      password: password,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _session = session;
    });
  }

  @override
  Widget build(BuildContext context) {
    final AuthSession? session = _session;

    return MaterialApp(
      title: 'JuliaTalk',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: session == null
          ? LoginScreen(onLogin: _login)
          : ChatConversationHomeScreen(
              client: _httpClient,
              baseUri: widget.appConfig.apiBaseUri,
              session: session,
            ),
    );
  }
}

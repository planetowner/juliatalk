import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'core/config/app_config.dart';
import 'core/notifications/notification_service.dart';
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
  late final NotificationService _notificationService;
  late final ChatConversationHomeController _chatController;
  StreamSubscription<Map<String, dynamic>>? _notificationEventSubscription;

  AuthSession? _session;

  @override
  void initState() {
    super.initState();

    _httpClient = http.Client();
    _notificationService = NotificationService();
    _chatController = ChatConversationHomeController();
    _notificationEventSubscription = _notificationService.events.listen(
      _handleNotificationEvent,
    );

    _authApi = AuthApi(
      client: _httpClient,
      baseUri: widget.appConfig.apiBaseUri,
    );
  }

  @override
  void dispose() {
    unawaited(_notificationEventSubscription?.cancel());
    _chatController.dispose();
    _httpClient.close();
    super.dispose();
  }

  void _handleNotificationEvent(Map<String, dynamic> event) {
    if (event['type'] != 'notification.opened') {
      return;
    }

    final dynamic rawPayload = event['payload'];
    if (rawPayload is! Map) {
      return;
    }

    final Map<String, dynamic> payload = Map<String, dynamic>.from(rawPayload);
    final String? senderId = payload['sender_id'] as String?;
    if (senderId != null && senderId.isNotEmpty) {
      _chatController.openConversation(senderId);
    }
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

    unawaited(_configureNotifications(session));
  }

  Future<void> _configureNotifications(AuthSession session) async {
    try {
      await _notificationService.configure(
        apiBaseUri: widget.appConfig.apiBaseUri,
        session: session,
      );
    } on PlatformException catch (error) {
      debugPrint('Notification configuration failed: ${error.message}');
    } on MissingPluginException {
      debugPrint('Notification bridge is unavailable on this platform.');
    }
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
              controller: _chatController,
            ),
    );
  }
}

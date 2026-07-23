import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../features/auth/domain/auth_session.dart';

final class NotificationService {
  static const MethodChannel _methodChannel = MethodChannel(
    'juliatalk/notifications',
  );
  static const EventChannel _eventChannel = EventChannel(
    'juliatalk/notification-events',
  );

  bool get _isSupported {
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  }

  Stream<Map<String, dynamic>> get events {
    if (!_isSupported) {
      return const Stream<Map<String, dynamic>>.empty();
    }

    return _eventChannel
        .receiveBroadcastStream()
        .where((dynamic event) => event is Map)
        .map((dynamic event) => Map<String, dynamic>.from(event as Map));
  }

  Future<void> configure({
    required Uri apiBaseUri,
    required AuthSession session,
  }) async {
    if (!_isSupported) {
      return;
    }

    await _methodChannel.invokeMethod<void>('configure', <String, Object>{
      'apiBaseUrl': apiBaseUri.toString(),
      'accessToken': session.accessToken,
      'userId': session.user.id,
      'preferredLanguage': session.user.preferredLanguage,
    });
    await _methodChannel.invokeMethod<bool>('requestAuthorization');
    await _methodChannel.invokeMethod<void>('startVoIP');
  }

  Future<Map<String, dynamic>> getSettings() async {
    if (!_isSupported) {
      return const <String, dynamic>{};
    }

    final Map<dynamic, dynamic>? settings = await _methodChannel
        .invokeMapMethod<dynamic, dynamic>('getSettings');
    return Map<String, dynamic>.from(settings ?? const <dynamic, dynamic>{});
  }

  Future<void> setBadgeCount(int count) async {
    if (!_isSupported) {
      return;
    }

    await _methodChannel.invokeMethod<void>('setBadgeCount', <String, int>{
      'count': count,
    });
  }

  Future<void> setActiveChatSenderId(String senderId) async {
    if (!_isSupported) {
      return;
    }

    await _methodChannel.invokeMethod<void>(
      'setActiveChatSenderId',
      <String, String>{'senderId': senderId},
    );
  }

  Future<void> clearActiveChatSenderId(String senderId) async {
    if (!_isSupported) {
      return;
    }

    await _methodChannel.invokeMethod<void>(
      'clearActiveChatSenderId',
      <String, String>{'senderId': senderId},
    );
  }
}

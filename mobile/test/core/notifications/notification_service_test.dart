import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/core/notifications/notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('juliatalk/notifications');

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'clears delivered iOS notifications without changing the badge',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final List<MethodCall> methodCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            methodCalls.add(call);
            return null;
          });

      await NotificationService().clearDeliveredNotifications();

      expect(methodCalls, hasLength(1));
      expect(methodCalls.single.method, 'clearDeliveredNotifications');
      expect(methodCalls.single.arguments, isNull);
    },
  );
}

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/features/chat/data/photo_send_diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('copies every recorded photo timing line together', () async {
    String? copiedText;
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (
      MethodCall call,
    ) async {
      if (call.method == 'Clipboard.setData') {
        final Map<Object?, Object?> arguments =
            call.arguments as Map<Object?, Object?>;
        copiedText = arguments['text'] as String?;
      }

      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });

    recordPhotoSendDiagnostic('[photo-send] stage=trial_start photo_count=1');
    recordPhotoSendDiagnostic('[photo-send] stage=ui_total elapsed_ms=10.0');
    await copyPhotoSendDiagnosticsToClipboard();

    expect(
      copiedText,
      '[photo-send] stage=trial_start photo_count=1\n'
      '[photo-send] stage=ui_total elapsed_ms=10.0',
    );
  });
}

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/features/chat/data/chat_photo_library.dart';
import 'package:juliatalk/features/chat/data/chat_video_transcoder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('juliatalk/video-transcoder');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('returns the encoded file metadata from the iOS bridge', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'transcode');
          expect(call.arguments, <String, Object>{
            'input_path': '/tmp/source.mov',
          });
          return <String, Object>{
            'local_path': '/tmp/encoded.mp4',
            'file_name': 'encoded.mp4',
            'mime_type': 'video/mp4',
            'size_bytes': 3891466,
            'width': 1080,
            'height': 1920,
            'duration_ms': 9398,
          };
        });

    final ChatVideoTranscodeResult result =
        await const MethodChannelChatVideoTranscoder().transcode(
          source: ChatPhotoFile(
            bytes: Uint8List(0),
            fileName: 'source.mov',
            mimeType: 'video/quicktime',
            sizeBytes: 10767102,
            localPath: '/tmp/source.mov',
          ),
          width: 1080,
          height: 1920,
          duration: const Duration(milliseconds: 9398),
        );

    expect(result.localPath, '/tmp/encoded.mp4');
    expect(result.fileName, 'encoded.mp4');
    expect(result.mimeType, 'video/mp4');
    expect(result.sizeBytes, 3891466);
    expect(result.width, 1080);
    expect(result.height, 1920);
    expect(result.duration, const Duration(milliseconds: 9398));
    expect(result.uploadBytes, isNull);
  });
}

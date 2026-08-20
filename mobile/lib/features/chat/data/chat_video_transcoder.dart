import 'package:flutter/services.dart';

import 'chat_photo_library.dart';

final class ChatVideoTranscodeResult {
  const ChatVideoTranscodeResult({
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.width,
    required this.height,
    required this.duration,
    this.localPath,
    this.uploadBytes,
  });

  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final int width;
  final int height;
  final Duration duration;
  final String? localPath;
  final Uint8List? uploadBytes;
}

abstract interface class ChatVideoTranscoder {
  Future<ChatVideoTranscodeResult> transcode({
    required ChatPhotoFile source,
    required int width,
    required int height,
    required Duration duration,
  });
}

final class OriginalChatVideoTranscoder implements ChatVideoTranscoder {
  const OriginalChatVideoTranscoder();

  @override
  Future<ChatVideoTranscodeResult> transcode({
    required ChatPhotoFile source,
    required int width,
    required int height,
    required Duration duration,
  }) async {
    return ChatVideoTranscodeResult(
      fileName: source.fileName,
      mimeType: source.mimeType,
      sizeBytes: source.sizeBytes,
      width: width,
      height: height,
      duration: duration,
      localPath: source.localPath,
      uploadBytes: source.bytes,
    );
  }
}

final class MethodChannelChatVideoTranscoder implements ChatVideoTranscoder {
  const MethodChannelChatVideoTranscoder();

  static const MethodChannel _channel = MethodChannel(
    'juliatalk/video-transcoder',
  );

  @override
  Future<ChatVideoTranscodeResult> transcode({
    required ChatPhotoFile source,
    required int width,
    required int height,
    required Duration duration,
  }) async {
    final String? inputPath = source.localPath;

    if (inputPath == null || inputPath.isEmpty) {
      throw PlatformException(
        code: 'missing_input_path',
        message: 'The selected video has no local file path.',
      );
    }

    final Map<Object?, Object?>? value = await _channel
        .invokeMapMethod<Object?, Object?>('transcode', <String, Object>{
          'input_path': inputPath,
        });

    if (value == null) {
      throw PlatformException(
        code: 'invalid_transcode_result',
        message: 'The video encoder returned no result.',
      );
    }

    return ChatVideoTranscodeResult(
      fileName: _requiredString(value, 'file_name'),
      mimeType: _requiredString(value, 'mime_type'),
      sizeBytes: _requiredInt(value, 'size_bytes'),
      width: _requiredInt(value, 'width'),
      height: _requiredInt(value, 'height'),
      duration: Duration(milliseconds: _requiredInt(value, 'duration_ms')),
      localPath: _requiredString(value, 'local_path'),
    );
  }

  static String _requiredString(Map<Object?, Object?> value, String key) {
    final Object? field = value[key];

    if (field is String && field.isNotEmpty) {
      return field;
    }

    throw PlatformException(
      code: 'invalid_transcode_result',
      message: 'The video encoder returned an invalid $key.',
    );
  }

  static int _requiredInt(Map<Object?, Object?> value, String key) {
    final Object? field = value[key];

    if (field is int && field >= 0) {
      return field;
    }

    throw PlatformException(
      code: 'invalid_transcode_result',
      message: 'The video encoder returned an invalid $key.',
    );
  }
}

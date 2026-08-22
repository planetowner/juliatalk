import 'dart:io';

import 'package:path_provider/path_provider.dart';

final class ChatVideoDiskCache {
  static Future<File> fileFor({
    required String mediaAssetId,
    required String? fileName,
  }) async {
    final Directory cacheDirectory = await getApplicationCacheDirectory();
    final String extension = fileExtension(fileName);

    return File('${cacheDirectory.path}/chat-videos/$mediaAssetId.$extension');
  }

  static Future<File?> retainLocalFile({
    required String mediaAssetId,
    required String? fileName,
    required String localPath,
  }) async {
    final File source = File(localPath);

    if (!await isUsable(source)) {
      return null;
    }

    try {
      final Directory cacheDirectory = await getApplicationCacheDirectory();
      final String extension = fileExtension(fileName);
      final Directory videoDirectory = Directory(
        '${cacheDirectory.path}/chat-videos',
      );
      final File target = File(
        '${videoDirectory.path}/$mediaAssetId.$extension',
      );

      if (source.absolute.path == target.absolute.path) {
        return source;
      }

      if (await isUsable(target)) {
        await _removeEncodedUploadIfOwned(source, cacheDirectory);
        return target;
      }

      await videoDirectory.create(recursive: true);

      if (await target.exists()) {
        await target.delete();
      }

      final Directory uploadDirectory = Directory(
        '${cacheDirectory.path}/video-uploads',
      );

      if (source.parent.absolute.path == uploadDirectory.absolute.path) {
        return source.rename(target.path);
      }

      final File partial = File('${target.path}.part');

      if (await partial.exists()) {
        await partial.delete();
      }

      await source.copy(partial.path);
      return partial.rename(target.path);
    } catch (_) {
      return await isUsable(source) ? source : null;
    }
  }

  static Future<bool> isUsable(File file) async {
    try {
      return await file.exists() && await file.length() > 0;
    } catch (_) {
      return false;
    }
  }

  static String fileExtension(String? fileName) {
    final String name = fileName ?? '';
    final int dotIndex = name.lastIndexOf('.');

    if (dotIndex < 0 || dotIndex == name.length - 1) {
      return 'mp4';
    }

    return name.substring(dotIndex + 1).toLowerCase();
  }

  static Future<void> _removeEncodedUploadIfOwned(
    File source,
    Directory cacheDirectory,
  ) async {
    final Directory uploadDirectory = Directory(
      '${cacheDirectory.path}/video-uploads',
    );

    if (source.parent.absolute.path != uploadDirectory.absolute.path) {
      return;
    }

    try {
      await source.delete();
    } catch (_) {
      return;
    }
  }
}

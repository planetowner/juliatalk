import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:juliatalk/design_system/app_theme.dart';
import 'package:juliatalk/features/chat/data/chat_photo_library.dart';
import 'package:juliatalk/features/chat/domain/chat_message.dart';
import 'package:juliatalk/features/chat/presentation/chat_conversation_view.dart';

final Uint8List _testPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB'
  'CAYAAAAfFcSJAAAADUlEQVR42mNk+M/w'
  'HwAEAQH/2p3KAAAAAElFTkSuQmCC',
);

final class TestChatPhotoLibrary implements ChatPhotoLibrary {
  const TestChatPhotoLibrary();

  static const List<ChatPhotoAlbum> _albums = <ChatPhotoAlbum>[
    ChatPhotoAlbum(
      id: 'all',
      name: 'Recents',
      assetCount: 12,
      isAll: true,
      coverAssetId: 'asset-0',
    ),
    ChatPhotoAlbum(
      id: 'favorites',
      name: 'Favorites',
      assetCount: 2,
      isAll: false,
      coverAssetId: 'favorite-0',
    ),
  ];

  static final Map<String, List<ChatPhotoAsset>> _assetsByAlbum =
      <String, List<ChatPhotoAsset>>{
        'all': List<ChatPhotoAsset>.generate(
          12,
          (int index) =>
              ChatPhotoAsset(id: 'asset-$index', width: 1200, height: 900),
        ),
        'favorites': List<ChatPhotoAsset>.generate(
          2,
          (int index) =>
              ChatPhotoAsset(id: 'favorite-$index', width: 900, height: 1200),
        ),
      };

  @override
  Future<ChatPhotoAccessState> requestAccess() async {
    return ChatPhotoAccessState.authorized;
  }

  @override
  Future<List<ChatPhotoAlbum>> loadAlbums() async {
    return _albums;
  }

  @override
  Future<List<ChatPhotoAsset>> loadAssets({
    required String albumId,
    required int page,
    required int pageSize,
  }) async {
    final List<ChatPhotoAsset> source =
        _assetsByAlbum[albumId] ?? const <ChatPhotoAsset>[];
    final int start = page * pageSize;

    if (start >= source.length) {
      return const <ChatPhotoAsset>[];
    }

    final int end = (start + pageSize).clamp(0, source.length);

    return source.sublist(start, end);
  }

  @override
  Future<Uint8List?> loadThumbnail({
    required String assetId,
    required int width,
    required int height,
  }) async {
    return _testPng;
  }

  @override
  Future<Uint8List?> loadMessagePreview({required String assetId}) async {
    return _testPng;
  }

  @override
  Future<ChatPhotoFile?> loadOriginalFile({required String assetId}) async {
    return ChatPhotoFile(
      bytes: _testPng,
      fileName: '$assetId.png',
      mimeType: 'image/png',
      sizeBytes: _testPng.length,
    );
  }

  @override
  Future<void> openSettings() async {}
}

final class JuliaTalkPreviewApp extends StatelessWidget {
  const JuliaTalkPreviewApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JuliaTalk',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: ChatConversationView(
        photoLibrary: const TestChatPhotoLibrary(),
        initialMessages: buildPreviewMessages(),
        initialClock: DateTime(2026, 7, 1, 12, 51),
        nextLocalMessageId: 9,
        translationDelay: const Duration(seconds: 5),
        onTranslateMessage: translatePreviewMessage,
      ),
    );
  }
}

List<ChatMessage> buildPreviewMessages() {
  return <ChatMessage>[
    ChatMessage(
      id: '1',
      senderId: '2',
      recipientId: '1',
      content: '欧巴我快要登机了',
      translationStatus: ChatTranslationStatus.none,
      createdAt: DateTime(2026, 6, 30, 20, 30, 5),
    ),
    ChatMessage(
      id: '2',
      senderId: '2',
      recipientId: '1',
      content: '我等你继续说呢',
      translatedContent: '네가 계속 말해주길 기다리고 있어.',
      translationStatus: ChatTranslationStatus.translated,
      createdAt: DateTime(2026, 6, 30, 20, 30, 45),
    ),
    ChatMessage(
      id: '3',
      senderId: '1',
      recipientId: '2',
      content: '알아 장난이야',
      createdAt: DateTime(2026, 6, 30, 20, 31, 10),
      readAt: DateTime(2026, 6, 30, 20, 33, 50),
    ),
    ChatMessage(
      id: '4',
      senderId: '1',
      recipientId: '2',
      content: '타이밍이 웃겨서',
      createdAt: DateTime(2026, 6, 30, 20, 31, 40),
      readAt: DateTime(2026, 6, 30, 20, 34, 10),
    ),
    ChatMessage(
      id: '5',
      senderId: '2',
      recipientId: '1',
      content: '抱歉啦欧巴',
      translatedContent: '미안해, 오빠.',
      translationStatus: ChatTranslationStatus.translated,
      createdAt: DateTime(2026, 6, 30, 20, 32, 5),
    ),
    ChatMessage(
      id: '6',
      senderId: '2',
      recipientId: '1',
      content: '我下次会好好说的',
      translationStatus: ChatTranslationStatus.failed,
      translationFailureReason: 'Network error',
      createdAt: DateTime(2026, 6, 30, 20, 32, 40),
    ),
    ChatMessage(
      id: '7',
      senderId: '1',
      recipientId: '2',
      content: '나 곧 탑승하는데',
      createdAt: DateTime(2026, 6, 30, 20, 34, 5),
    ),
    ChatMessage(
      id: '8',
      senderId: '1',
      recipientId: '2',
      content: '너는 계속 얘기해도 돼',
      createdAt: DateTime(2026, 6, 30, 20, 34, 45),
    ),
    ChatMessage(
      id: '101',
      senderId: '2',
      recipientId: '1',
      content: '那如果有一天我变成虫子了 欧巴怎么办',
      createdAt: DateTime(2026, 7, 1, 12, 45, 5),
    ),
    ChatMessage(
      id: '102',
      senderId: '2',
      recipientId: '1',
      content: '🥺',
      createdAt: DateTime(2026, 7, 1, 12, 45, 35),
    ),
    ChatMessage(
      id: '103',
      senderId: '1',
      recipientId: '2',
      content: '알 낳을거야?',
      createdAt: DateTime(2026, 7, 1, 12, 47, 5),
      readAt: DateTime(2026, 7, 1, 12, 50, 30),
    ),
    ChatMessage(
      id: '104',
      senderId: '1',
      recipientId: '2',
      content: '더 번식 안 하고 너만 있는거면 내가 잘 키워줄게',
      createdAt: DateTime(2026, 7, 1, 12, 47, 35),
      readAt: DateTime(2026, 7, 1, 12, 50, 30),
    ),
    ChatMessage(
      id: '105',
      senderId: '2',
      recipientId: '1',
      content: '下蛋🥚？？',
      createdAt: DateTime(2026, 7, 1, 12, 50, 5),
    ),
    ChatMessage(
      id: '106',
      senderId: '2',
      recipientId: '1',
      content: '哈哈哈哈哈哈哈哈哈哈哈哈哈',
      createdAt: DateTime(2026, 7, 1, 12, 50, 25),
    ),
    ChatMessage(
      id: '107',
      senderId: '2',
      recipientId: '1',
      content: '那可以放养吗 我不想被关进笼子里 还想和你抱抱睡觉觉 然后亲亲',
      createdAt: DateTime(2026, 7, 1, 12, 50, 45),
    ),
  ];
}

Future<String?> translatePreviewMessage(ChatMessage message) async {
  return _previewTranslations[message.id];
}

const Map<String, String> _previewTranslations = <String, String>{
  '1': '오빠, 나 곧 탑승해.',
  '2': '네가 계속 말해주길 기다리고 있어.',
  '5': '미안해, 오빠.',
  '6': '다음에는 제대로 말할게.',
  '101': '그럼 만약 어느 날 내가 벌레가 되면 오빠는 어떻게 할 거야?',
  '102': '🥺',
  '105': '알을 낳는다고🥚??',
  '106': 'ㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋ',
  '107':
      '그럼 풀어놓고 키워도 돼? 나는 새장에 갇히고 싶지 않고, '
      '오빠랑 꼭 안고 자고 뽀뽀도 하고 싶어.',
};

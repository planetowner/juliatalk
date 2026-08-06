import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/design_system/app_theme.dart';
import 'package:juliatalk/features/chat/data/chat_photo_library.dart';
import 'package:juliatalk/features/chat/domain/chat_message.dart';
import 'package:juliatalk/features/chat/presentation/chat_conversation_view.dart';

final Uint8List _testPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB'
  'CAYAAAAfFcSJAAAADUlEQVR42mNk+M/w'
  'HwAEAQH/2p3KAAAAAElFTkSuQmCC',
);

final class _QuickPhotoLibrary
    implements ChatPhotoLibrary, ChatQuickPhotoSource {
  _QuickPhotoLibrary({required this.latestPhoto});

  ChatPhotoAsset? latestPhoto;
  int latestPhotoLoadCount = 0;

  @override
  Future<ChatPhotoAccessState> checkAccess() async {
    return ChatPhotoAccessState.authorized;
  }

  @override
  Future<ChatPhotoAsset?> loadLatestPhoto() async {
    latestPhotoLoadCount++;
    return latestPhoto;
  }

  @override
  Future<ChatPhotoAccessState> requestAccess() async {
    return ChatPhotoAccessState.authorized;
  }

  @override
  Future<List<ChatPhotoAlbum>> loadAlbums() async {
    return const <ChatPhotoAlbum>[];
  }

  @override
  Future<List<ChatPhotoAsset>> loadAssets({
    required String albumId,
    required int page,
    required int pageSize,
  }) async {
    return const <ChatPhotoAsset>[];
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

ChatPhotoAsset _photoCreated(Duration ago, {String id = 'recent-photo'}) {
  return ChatPhotoAsset(
    id: id,
    width: 1290,
    height: 2796,
    createdAt: DateTime.now().subtract(ago),
  );
}

Widget _buildScreen(_QuickPhotoLibrary photoLibrary) {
  return MaterialApp(
    theme: AppTheme.light,
    home: ChatConversationView(
      photoLibrary: photoLibrary,
      initialMessages: const <ChatMessage>[],
    ),
  );
}

Future<void> _tapAttachmentButton(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('message-attachment')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  testWidgets('shows a photo created within 15 seconds when plus is pressed', (
    WidgetTester tester,
  ) async {
    final _QuickPhotoLibrary photoLibrary = _QuickPhotoLibrary(
      latestPhoto: _photoCreated(const Duration(seconds: 14)),
    );

    await tester.pumpWidget(_buildScreen(photoLibrary));
    await _tapAttachmentButton(tester);

    final Finder prompt = find.byKey(
      const ValueKey<String>('quick-photo-prompt'),
    );
    final Finder composer = find.byKey(
      const ValueKey<String>('message-composer-default'),
    );
    final Finder thumbnail = find.byKey(
      const ValueKey<String>('quick-photo-thumbnail'),
    );
    final Finder surface = find.byKey(
      const ValueKey<String>('quick-photo-card-surface'),
    );
    final Finder sendButton = find.byKey(
      const ValueKey<String>('quick-photo-send'),
    );

    expect(prompt, findsOneWidget);

    final Rect promptRect = tester.getRect(prompt);
    final Rect composerRect = tester.getRect(composer);
    final Rect thumbnailRect = tester.getRect(thumbnail);
    final Rect sendButtonRect = tester.getRect(sendButton);
    final double screenWidth = tester
        .getSize(find.byType(Scaffold).first)
        .width;
    final double expectedPromptWidth = (screenWidth * 0.172)
        .clamp(68, 76)
        .toDouble();

    expect(screenWidth - promptRect.right, moreOrLessEquals(8));
    expect(composerRect.top - promptRect.bottom, moreOrLessEquals(12));
    expect(promptRect.width, moreOrLessEquals(expectedPromptWidth));
    expect(promptRect.height, moreOrLessEquals(expectedPromptWidth + 50));
    expect(thumbnailRect.left, moreOrLessEquals(promptRect.left));
    expect(thumbnailRect.top, moreOrLessEquals(promptRect.top));
    expect(thumbnailRect.right, moreOrLessEquals(promptRect.right));
    expect(sendButtonRect.width, moreOrLessEquals(promptRect.width - 12));
    expect(sendButtonRect.height, moreOrLessEquals(32));

    final BoxDecoration decoration =
        tester.widget<DecoratedBox>(surface).decoration as BoxDecoration;
    final BoxShadow shadow = decoration.boxShadow!.single;

    expect(
      decoration.borderRadius,
      const BorderRadius.all(Radius.circular(17)),
    );
    expect(decoration.border, isNull);
    expect(decoration.color, const Color(0xFFFFFFFF));
    expect(shadow.color, const Color(0x1A000000));
    expect(shadow.offset, const Offset(0, 6));
    expect(shadow.blurRadius, 18);
  });

  testWidgets('fades an untouched quick photo out after ten seconds', (
    WidgetTester tester,
  ) async {
    final _QuickPhotoLibrary photoLibrary = _QuickPhotoLibrary(
      latestPhoto: _photoCreated(const Duration(seconds: 1)),
    );

    await tester.pumpWidget(_buildScreen(photoLibrary));
    await _tapAttachmentButton(tester);

    final Finder prompt = find.byKey(
      const ValueKey<String>('quick-photo-prompt'),
    );
    final Finder opacity = find.ancestor(
      of: prompt,
      matching: find.byType(AnimatedOpacity),
    );

    expect(prompt, findsOneWidget);
    expect(opacity, findsOneWidget);

    final AnimatedOpacity animatedOpacity = tester.widget<AnimatedOpacity>(
      opacity,
    );

    expect(animatedOpacity.duration, const Duration(milliseconds: 180));
    expect(animatedOpacity.curve, Curves.linear);

    await tester.pump(const Duration(seconds: 9));
    expect(prompt, findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    expect(prompt, findsNothing);

    await _tapAttachmentButton(tester);
    await _tapAttachmentButton(tester);
    expect(prompt, findsNothing);
  });

  testWidgets('does not show a photo older than 15 seconds', (
    WidgetTester tester,
  ) async {
    final _QuickPhotoLibrary photoLibrary = _QuickPhotoLibrary(
      latestPhoto: _photoCreated(const Duration(seconds: 16)),
    );

    await tester.pumpWidget(_buildScreen(photoLibrary));
    await _tapAttachmentButton(tester);

    expect(
      find.byKey(const ValueKey<String>('quick-photo-prompt')),
      findsNothing,
    );
  });

  testWidgets('shows the quick photo when plus is pressed from the keyboard', (
    WidgetTester tester,
  ) async {
    final _QuickPhotoLibrary photoLibrary = _QuickPhotoLibrary(
      latestPhoto: _photoCreated(const Duration(seconds: 1)),
    );

    await tester.pumpWidget(_buildScreen(photoLibrary));
    await tester.tap(find.byKey(const ValueKey<String>('message-input')));
    await tester.pump();

    await _tapAttachmentButton(tester);

    expect(
      find.byKey(const ValueKey<String>('quick-photo-prompt')),
      findsOneWidget,
    );
  });

  testWidgets('shows each recent photo only once', (WidgetTester tester) async {
    final _QuickPhotoLibrary photoLibrary = _QuickPhotoLibrary(
      latestPhoto: _photoCreated(const Duration(seconds: 1)),
    );

    await tester.pumpWidget(_buildScreen(photoLibrary));
    await _tapAttachmentButton(tester);

    expect(
      find.byKey(const ValueKey<String>('quick-photo-prompt')),
      findsOneWidget,
    );

    await _tapAttachmentButton(tester);
    await _tapAttachmentButton(tester);

    expect(
      find.byKey(const ValueKey<String>('quick-photo-prompt')),
      findsNothing,
    );
  });

  testWidgets('does not react to a new photo while the panel is already open', (
    WidgetTester tester,
  ) async {
    final _QuickPhotoLibrary photoLibrary = _QuickPhotoLibrary(
      latestPhoto: _photoCreated(const Duration(seconds: 30), id: 'old-photo'),
    );

    await tester.pumpWidget(_buildScreen(photoLibrary));
    await _tapAttachmentButton(tester);

    expect(photoLibrary.latestPhotoLoadCount, 1);
    expect(
      find.byKey(const ValueKey<String>('quick-photo-prompt')),
      findsNothing,
    );

    photoLibrary.latestPhoto = _photoCreated(
      const Duration(seconds: 1),
      id: 'new-photo',
    );
    await tester.pump(const Duration(seconds: 1));

    expect(photoLibrary.latestPhotoLoadCount, 1);
    expect(
      find.byKey(const ValueKey<String>('quick-photo-prompt')),
      findsNothing,
    );

    await _tapAttachmentButton(tester);
    await _tapAttachmentButton(tester);

    expect(photoLibrary.latestPhotoLoadCount, 2);
    expect(
      find.byKey(const ValueKey<String>('quick-photo-prompt')),
      findsOneWidget,
    );
  });

  testWidgets('opens a preview before sending the quick photo', (
    WidgetTester tester,
  ) async {
    final _QuickPhotoLibrary photoLibrary = _QuickPhotoLibrary(
      latestPhoto: _photoCreated(const Duration(seconds: 1)),
    );

    await tester.pumpWidget(_buildScreen(photoLibrary));
    await _tapAttachmentButton(tester);

    await tester.tap(find.byKey(const ValueKey<String>('quick-photo-prompt')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    expect(
      find.byKey(const ValueKey<String>('quick-photo-preview')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('quick-photo-preview-send')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    expect(
      find.byKey(const ValueKey<String>('quick-photo-preview')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('quick-photo-prompt')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('attachment-panel')),
      findsNothing,
    );
  });
}

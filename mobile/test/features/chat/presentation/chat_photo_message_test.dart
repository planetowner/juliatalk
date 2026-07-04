import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/features/chat/domain/chat_message.dart';
import 'package:juliatalk/features/chat/presentation/chat_style_preview_screen.dart';

final Uint8List _testPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB'
  'CAYAAAAfFcSJAAAADUlEQVR42mNk+M/w'
  'HwAEAQH/2p3KAAAAAElFTkSuQmCC',
);

Widget _buildPhotoMessageScreen(ChatMessage message) {
  return MaterialApp(
    home: ChatStylePreviewScreen(initialMessages: <ChatMessage>[message]),
  );
}

ChatMessage _photoMessage({
  required int senderId,
  required int recipientId,
}) {
  return ChatMessage(
    id: 1,
    senderId: senderId,
    recipientId: recipientId,
    content: '',
    createdAt: DateTime(2026, 7, 1, 12, 52),
    photoAttachments: <ChatPhotoAttachment>[
      ChatPhotoAttachment(
        assetId: 'photo-preview-0',
        previewBytes: _testPng,
        width: 1200,
        height: 900,
      ),
    ],
  );
}

void main() {
  testWidgets('incoming photo messages render as incoming media bubbles', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildPhotoMessageScreen(_photoMessage(senderId: 2, recipientId: 1)),
    );
    await tester.pumpAndSettle();

    final Finder bubbleFinder = find.byKey(
      const ValueKey<String>('incoming-bubble-1'),
    );

    expect(bubbleFinder, findsOneWidget);
    expect(
      find.descendant(
        of: bubbleFinder,
        matching: find.byKey(
          const ValueKey<String>('photo-message-photo-preview-0-0'),
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: bubbleFinder,
        matching: find.byKey(const ValueKey<String>('original-message-1')),
      ),
      findsNothing,
    );

    await tester.tap(bubbleFinder);
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('outgoing photo messages keep the outgoing media bubble key', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildPhotoMessageScreen(_photoMessage(senderId: 1, recipientId: 2)),
    );
    await tester.pumpAndSettle();

    final Finder bubbleFinder = find.byKey(
      const ValueKey<String>('outgoing-bubble-1'),
    );

    expect(bubbleFinder, findsOneWidget);
    expect(
      find.descendant(
        of: bubbleFinder,
        matching: find.byKey(
          const ValueKey<String>('photo-message-photo-preview-0-0'),
        ),
      ),
      findsOneWidget,
    );
  });
}

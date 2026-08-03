import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/features/chat/domain/chat_message.dart';
import 'package:juliatalk/features/chat/presentation/chat_conversation_view.dart';

const String _previewUrl =
    'https://rent.heykorean.com/rent/view/1090440';

Widget _buildLinkPreviewScreen() {
  return MaterialApp(
    home: ChatConversationView(
      initialMessages: <ChatMessage>[
        ChatMessage(
          id: '1',
          senderId: '2',
          recipientId: '1',
          content: _previewUrl,
          createdAt: DateTime(2026, 8, 3, 18, 35),
          linkPreview: const ChatLinkPreview(
            url: _previewUrl,
            canonicalUrl: _previewUrl,
            domain: 'rent.heykorean.com',
            title: 'StuyTown 거실룸 룸메이트 구해요 !',
            description: 'StuyTown 거실룸 룸메이트 구해요 !',
            siteName: 'StuyTown 거실룸 룸메이트 구해요 !',
          ),
        ),
      ],
    ),
  );
}

void main() {
  testWidgets('link preview images use the KakaoTalk two-to-one ratio', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_buildLinkPreviewScreen());
    await tester.pump();

    final Finder imageFinder = find.byKey(
      ValueKey<String>('link-preview-image-$_previewUrl'),
    );

    expect(imageFinder, findsOneWidget);

    final Size imageSize = tester.getSize(imageFinder);

    expect(imageSize.width / imageSize.height, closeTo(2, 0.001));
    expect(
      find.text('StuyTown 거실룸 룸메이트 구해요 !'),
      findsWidgets,
    );
    expect(find.text('rent.heykorean.com'), findsOneWidget);
  });
}

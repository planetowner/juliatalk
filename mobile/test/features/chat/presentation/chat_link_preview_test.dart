import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/features/chat/domain/chat_message.dart';
import 'package:juliatalk/features/chat/presentation/chat_conversation_view.dart';

const String _previewUrl = 'https://rent.heykorean.com/rent/view/1090440';

Widget _buildLinkPreviewScreen({
  String senderId = '2',
  String content = _previewUrl,
  ChatLinkOpener? onOpenLink,
}) {
  return MaterialApp(
    home: ChatConversationView(
      onOpenLink: onOpenLink,
      initialMessages: <ChatMessage>[
        ChatMessage(
          id: '1',
          senderId: senderId,
          recipientId: senderId == '1' ? '2' : '1',
          content: content,
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
    await tester.pumpAndSettle();

    final Finder imageFinder = find.byKey(
      ValueKey<String>('link-preview-image-$_previewUrl'),
    );

    expect(imageFinder, findsOneWidget);

    final Size imageSize = tester.getSize(imageFinder);

    expect(imageSize.width / imageSize.height, closeTo(2, 0.001));
    expect(find.text('StuyTown 거실룸 룸메이트 구해요 !'), findsWidgets);
    expect(find.text('rent.heykorean.com'), findsOneWidget);
  });

  for (final bool outgoing in <bool>[false, true]) {
    testWidgets(
      '${outgoing ? 'outgoing' : 'incoming'} link preview card opens the original URL',
      (WidgetTester tester) async {
        Uri? openedUri;

        await tester.pumpWidget(
          _buildLinkPreviewScreen(
            senderId: outgoing ? '1' : '2',
            onOpenLink: (Uri uri) async {
              openedUri = uri;
              return true;
            },
          ),
        );
        await tester.pumpAndSettle();

        final Finder cardFinder = find.byKey(
          const ValueKey<String>('link-preview-card-$_previewUrl'),
        );

        await tester.ensureVisible(cardFinder);
        await tester.pump();
        await tester.tap(cardFinder);
        await tester.pump();

        expect(openedUri, Uri.parse(_previewUrl));
      },
    );
  }

  testWidgets('a failed link open shows an in-app error', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildLinkPreviewScreen(onOpenLink: (_) async => false),
    );
    await tester.pumpAndSettle();

    final Finder cardFinder = find.byKey(
      const ValueKey<String>('link-preview-card-$_previewUrl'),
    );

    await tester.ensureVisible(cardFinder);
    await tester.pump();
    await tester.tap(cardFinder);
    await tester.pump();

    expect(find.text('Unable to open this link.'), findsOneWidget);
  });
}

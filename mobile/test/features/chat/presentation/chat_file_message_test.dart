import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/design_system/app_colors.dart';
import 'package:juliatalk/design_system/app_typography.dart';
import 'package:juliatalk/features/chat/domain/chat_message.dart';
import 'package:juliatalk/features/chat/presentation/chat_conversation_view.dart';

Widget _buildFileMessageScreen(ChatMessage message) {
  return MaterialApp(
    home: ChatConversationView(initialMessages: <ChatMessage>[message]),
  );
}

ChatMessage _fileMessage({
  required String senderId,
  required String recipientId,
}) {
  return ChatMessage(
    id: '1',
    senderId: senderId,
    recipientId: recipientId,
    content: '',
    createdAt: DateTime(2026, 7, 1, 12, 52),
    fileAttachment: const ChatFileAttachment(
      name: 'Report_v2.bin',
      sizeBytes: 350 * 1024,
    ),
  );
}

void main() {
  testWidgets('outgoing file messages match the outgoing bubble tone', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildFileMessageScreen(_fileMessage(senderId: '1', recipientId: '2')),
    );
    await tester.pumpAndSettle();

    final Finder bubbleFinder = find.byKey(
      const ValueKey<String>('outgoing-bubble-1'),
    );

    expect(bubbleFinder, findsOneWidget);
    expect(
      find.descendant(of: bubbleFinder, matching: find.text('Report_v2.bin')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bubbleFinder, matching: find.text('350 KB')),
      findsOneWidget,
    );

    final Text title = tester.widget<Text>(find.text('Report_v2.bin'));
    final Text metadata = tester.widget<Text>(find.text('350 KB'));
    final Icon icon = tester.widget<Icon>(
      find.descendant(
        of: bubbleFinder,
        matching: find.byIcon(Icons.insert_drive_file_rounded),
      ),
    );

    expect(title.style?.color, AppColors.white);
    expect(title.style?.fontSize, AppTypography.typography6.fontSize);
    expect(title.style?.fontWeight, AppTypography.medium);
    expect(metadata.style?.color, AppColors.white.withAlpha(200));
    expect(icon.color, AppColors.white);

    await tester.tap(find.text('Report_v2.bin'));
    await tester.pump();

    expect(find.text('File preview is not available yet.'), findsOneWidget);
  });

  testWidgets('incoming file messages use incoming colors without translation', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildFileMessageScreen(_fileMessage(senderId: '2', recipientId: '1')),
    );
    await tester.pumpAndSettle();

    final Finder bubbleFinder = find.byKey(
      const ValueKey<String>('incoming-bubble-1'),
    );

    expect(bubbleFinder, findsOneWidget);
    expect(
      find.descendant(of: bubbleFinder, matching: find.text('Report_v2.bin')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bubbleFinder, matching: find.text('350 KB')),
      findsOneWidget,
    );

    final Text title = tester.widget<Text>(find.text('Report_v2.bin'));
    final Text metadata = tester.widget<Text>(find.text('350 KB'));
    final Icon icon = tester.widget<Icon>(
      find.descendant(
        of: bubbleFinder,
        matching: find.byIcon(Icons.insert_drive_file_rounded),
      ),
    );

    expect(title.style?.color, AppColors.grey900);
    expect(title.style?.fontSize, AppTypography.typography6.fontSize);
    expect(title.style?.fontWeight, AppTypography.medium);
    expect(metadata.style?.color, AppColors.grey500);
    expect(icon.color, AppColors.blue500);

    await tester.tap(find.text('Report_v2.bin'));
    await tester.pump();

    expect(find.text('File preview is not available yet.'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/features/chat/domain/chat_message.dart';
import 'package:juliatalk/features/chat/presentation/chat_conversation_view.dart';

Widget _buildVoiceMemoScreen(ChatMessage message, {DateTime? initialClock}) {
  return MaterialApp(
    home: ChatConversationView(
      initialMessages: <ChatMessage>[message],
      currentUserId: '1',
      initialClock: initialClock,
    ),
  );
}

ChatMessage _voiceMemoMessage({
  String senderId = '1',
  String recipientId = '2',
}) {
  return ChatMessage(
    id: 'voice-1',
    senderId: senderId,
    recipientId: recipientId,
    content: '',
    createdAt: DateTime(2026, 7, 4, 17, 16),
    voiceMemoAttachment: const ChatVoiceMemoAttachment(
      duration: Duration(seconds: 3),
      waveformSamples: <double>[0.1, 0.2, 0.5, 0.8, 0.4, 0.2],
    ),
  );
}

void main() {
  testWidgets('outgoing voice memo menu allows reply and unsend only', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildVoiceMemoScreen(
        _voiceMemoMessage(),
        initialClock: DateTime(2026, 7, 4, 17, 16, 30),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(
      find.byKey(const ValueKey<String>('outgoing-bubble-voice-1')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Reply'), findsOneWidget);
    expect(find.text('Unsend'), findsOneWidget);
    expect(find.text('Copy'), findsNothing);
    expect(find.text('Edit'), findsNothing);
  });

  testWidgets('incoming voice memo menu only allows reply', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildVoiceMemoScreen(
        _voiceMemoMessage(senderId: '2', recipientId: '1'),
        initialClock: DateTime(2026, 7, 4, 17, 16, 30),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(
      find.byKey(const ValueKey<String>('incoming-bubble-voice-1')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Reply'), findsOneWidget);
    expect(find.text('Copy'), findsNothing);
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Unsend'), findsNothing);
  });
}

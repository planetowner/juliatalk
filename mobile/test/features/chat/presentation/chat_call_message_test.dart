import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/features/chat/domain/chat_message.dart';
import 'package:juliatalk/features/chat/presentation/chat_style_preview_screen.dart';

Widget _buildCallMessageScreen(ChatMessage message) {
  final ChatCallAttachment attachment = message.callAttachment!;

  return MaterialApp(
    home: ChatStylePreviewScreen(
      key: ValueKey<String>(
        'call-${attachment.outcome.name}-${attachment.duration.inSeconds}',
      ),
      initialMessages: <ChatMessage>[message],
    ),
  );
}

ChatMessage _callMessage({
  required ChatCallOutcome outcome,
  Duration duration = Duration.zero,
}) {
  return ChatMessage(
    id: 1,
    senderId: 1,
    recipientId: 2,
    content: '',
    createdAt: DateTime(2026, 7, 4, 17, 16),
    callAttachment: ChatCallAttachment(
      kind: ChatCallKind.voice,
      outcome: outcome,
      duration: duration,
    ),
  );
}

void main() {
  testWidgets('ended voice calls show the duration in the chat bubble', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildCallMessageScreen(
        _callMessage(
          outcome: ChatCallOutcome.ended,
          duration: const Duration(seconds: 34),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder bubbleFinder = find.byKey(
      const ValueKey<String>('outgoing-bubble-1'),
    );

    expect(bubbleFinder, findsOneWidget);
    expect(
      find.descendant(of: bubbleFinder, matching: find.text('End voice call')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bubbleFinder, matching: find.text('00:34')),
      findsOneWidget,
    );
  });

  testWidgets('call outcomes render their Kakao-style labels', (
    WidgetTester tester,
  ) async {
    const Map<ChatCallOutcome, String> expectedLabels =
        <ChatCallOutcome, String>{
      ChatCallOutcome.started: 'Voice Call',
      ChatCallOutcome.cancelled: 'Cancelled',
      ChatCallOutcome.missed: 'Missed Call',
      ChatCallOutcome.noAnswer: 'No Answer',
    };

    for (final MapEntry<ChatCallOutcome, String> entry
        in expectedLabels.entries) {
      await tester.pumpWidget(
        _buildCallMessageScreen(_callMessage(outcome: entry.key)),
      );
      await tester.pumpAndSettle();

      final Finder bubbleFinder = find.byKey(
        const ValueKey<String>('outgoing-bubble-1'),
      );

      expect(bubbleFinder, findsOneWidget);
      expect(
        find.descendant(of: bubbleFinder, matching: find.text(entry.value)),
        findsOneWidget,
      );
    }
  });
}

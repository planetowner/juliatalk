import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/design_system/app_colors.dart';
import 'package:juliatalk/features/chat/domain/chat_message.dart';
import 'package:juliatalk/features/chat/presentation/chat_conversation_view.dart';

Widget _buildCallMessageScreen(
  ChatMessage message, {
  String currentUserId = '1',
}) {
  final ChatCallAttachment attachment = message.callAttachment!;

  return MaterialApp(
    home: ChatConversationView(
      key: ValueKey<String>(
        'call-${message.senderId}-${message.recipientId}-'
        '${attachment.outcome.name}-${attachment.duration.inSeconds}',
      ),
      initialMessages: <ChatMessage>[message],
      currentUserId: currentUserId,
    ),
  );
}

ChatMessage _callMessage({
  required ChatCallOutcome outcome,
  Duration duration = Duration.zero,
  String senderId = '1',
  String recipientId = '2',
}) {
  return ChatMessage(
    id: '1',
    senderId: senderId,
    recipientId: recipientId,
    content: '',
    createdAt: DateTime(2026, 7, 4, 17, 16),
    callAttachment: ChatCallAttachment(
      kind: ChatCallKind.voice,
      outcome: outcome,
      duration: duration,
    ),
  );
}

Finder _callBubbleFinder(WidgetTester tester) {
  final Finder outgoingBubbleFinder = find.byKey(
    const ValueKey<String>('outgoing-bubble-1'),
  );

  if (outgoingBubbleFinder.evaluate().isNotEmpty) {
    return outgoingBubbleFinder;
  }

  return find.byKey(const ValueKey<String>('incoming-bubble-1'));
}

Finder _incomingCallBubbleFinder() {
  return find.byKey(const ValueKey<String>('incoming-bubble-1'));
}

void _expectCallTextIsFullyVisible(WidgetTester tester, Finder textFinder) {
  final Text text = tester.widget<Text>(textFinder);

  expect(text.maxLines, 1);
  expect(text.softWrap, isFalse);
  expect(text.overflow, TextOverflow.visible);
  expect(text.strutStyle, isNotNull);
  expect(text.textHeightBehavior, isNotNull);
}

void _expectCallBubbleGeometry(
  WidgetTester tester, {
  required String label,
  String? duration,
}) {
  const double horizontalPadding = 11;
  const double iconLabelGap = 10;
  const double tolerance = 1;

  final Finder bubbleFinder = _callBubbleFinder(tester);
  final Finder iconSlotFinder = find.descendant(
    of: bubbleFinder,
    matching: find.byKey(const ValueKey<String>('call-icon-slot-1')),
  );
  final Finder labelFinder = find.descendant(
    of: bubbleFinder,
    matching: find.text(label),
  );
  final Finder labelSlotFinder = find.descendant(
    of: bubbleFinder,
    matching: find.byKey(ValueKey<String>('call-text-slot-1-$label')),
  );
  final Rect bubbleRect = tester.getRect(bubbleFinder);
  final Rect iconSlotRect = tester.getRect(iconSlotFinder);
  final Rect labelSlotRect = tester.getRect(labelSlotFinder);

  expect(
    iconSlotRect.left - bubbleRect.left,
    closeTo(horizontalPadding, tolerance),
  );
  expect(
    labelSlotRect.left - iconSlotRect.right,
    closeTo(iconLabelGap, tolerance),
  );
  expect(
    bubbleRect.right - labelSlotRect.right,
    closeTo(horizontalPadding, tolerance),
  );
  expect(
    bubbleRect.width,
    closeTo(
      horizontalPadding +
          iconSlotRect.width +
          iconLabelGap +
          labelSlotRect.width +
          horizontalPadding,
      tolerance,
    ),
  );
  _expectCallTextIsFullyVisible(tester, labelFinder);

  if (duration == null) {
    return;
  }

  final Finder durationFinder = find.descendant(
    of: bubbleFinder,
    matching: find.text(duration),
  );
  final Finder durationSlotFinder = find.descendant(
    of: bubbleFinder,
    matching: find.byKey(ValueKey<String>('call-text-slot-1-$duration')),
  );
  final Rect durationSlotRect = tester.getRect(durationSlotFinder);

  expect(durationSlotRect.right, closeTo(labelSlotRect.right, tolerance));
  expect(
    bubbleRect.right - durationSlotRect.right,
    closeTo(horizontalPadding, tolerance),
  );
  _expectCallTextIsFullyVisible(tester, durationFinder);
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

    final Finder bubbleFinder = _callBubbleFinder(tester);

    expect(bubbleFinder, findsOneWidget);
    expect(
      find.descendant(of: bubbleFinder, matching: find.text('End voice call')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bubbleFinder, matching: find.text('00:34')),
      findsOneWidget,
    );
    _expectCallBubbleGeometry(
      tester,
      label: 'End voice call',
      duration: '00:34',
    );
  });

  testWidgets('call outcomes render their Kakao-style labels', (
    WidgetTester tester,
  ) async {
    const Map<ChatCallOutcome, String> expectedLabels =
        <ChatCallOutcome, String>{
          ChatCallOutcome.started: 'Voice Call',
          ChatCallOutcome.cancelled: 'Canceled',
          ChatCallOutcome.missed: 'Missed Call',
          ChatCallOutcome.noAnswer: 'No Answer',
        };

    for (final MapEntry<ChatCallOutcome, String> entry
        in expectedLabels.entries) {
      await tester.pumpWidget(
        _buildCallMessageScreen(_callMessage(outcome: entry.key)),
      );
      await tester.pumpAndSettle();

      final Finder bubbleFinder = _callBubbleFinder(tester);

      expect(bubbleFinder, findsOneWidget);
      expect(
        find.descendant(of: bubbleFinder, matching: find.text(entry.value)),
        findsOneWidget,
      );
    }
  });

  testWidgets('call bubbles stay compact like chat messages', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildCallMessageScreen(_callMessage(outcome: ChatCallOutcome.started)),
    );
    await tester.pumpAndSettle();

    final Finder startedBubbleFinder = _callBubbleFinder(tester);

    expect(tester.getSize(startedBubbleFinder).height, lessThanOrEqualTo(44));

    await tester.pumpWidget(
      _buildCallMessageScreen(
        _callMessage(
          outcome: ChatCallOutcome.ended,
          duration: const Duration(seconds: 34),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder endedBubbleFinder = _callBubbleFinder(tester);

    expect(tester.getSize(endedBubbleFinder).height, lessThanOrEqualTo(66));
    expect(
      find.descendant(
        of: endedBubbleFinder,
        matching: find.text('End voice call'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('call bubbles use full label width and symmetric padding', (
    WidgetTester tester,
  ) async {
    const Map<ChatCallOutcome, String> labels = <ChatCallOutcome, String>{
      ChatCallOutcome.started: 'Voice Call',
      ChatCallOutcome.cancelled: 'Canceled',
      ChatCallOutcome.missed: 'Missed Call',
    };

    final Map<ChatCallOutcome, double> bubbleWidths =
        <ChatCallOutcome, double>{};
    for (final MapEntry<ChatCallOutcome, String> entry in labels.entries) {
      await tester.pumpWidget(
        _buildCallMessageScreen(_callMessage(outcome: entry.key)),
      );
      await tester.pumpAndSettle();

      final Finder bubbleFinder = _callBubbleFinder(tester);
      final double bubbleWidth = tester.getSize(bubbleFinder).width;

      _expectCallBubbleGeometry(tester, label: entry.value);
      bubbleWidths[entry.key] = bubbleWidth;
    }

    expect(
      bubbleWidths[ChatCallOutcome.cancelled]!,
      lessThan(bubbleWidths[ChatCallOutcome.started]!),
    );
    expect(
      bubbleWidths[ChatCallOutcome.started]!,
      lessThan(bubbleWidths[ChatCallOutcome.missed]!),
    );
  });

  testWidgets('missed calls use a distinct red missed-call icon', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildCallMessageScreen(_callMessage(outcome: ChatCallOutcome.missed)),
    );
    await tester.pumpAndSettle();

    Finder bubbleFinder = _callBubbleFinder(tester);
    Icon icon = tester.widget<Icon>(
      find.descendant(of: bubbleFinder, matching: find.byType(Icon)),
    );

    expect(icon.icon, Icons.phone_missed_rounded);
    expect(icon.color, AppColors.red500);

    await tester.pumpWidget(
      _buildCallMessageScreen(_callMessage(outcome: ChatCallOutcome.noAnswer)),
    );
    await tester.pumpAndSettle();

    bubbleFinder = _callBubbleFinder(tester);
    icon = tester.widget<Icon>(
      find.descendant(of: bubbleFinder, matching: find.byType(Icon)),
    );

    expect(icon.icon, Icons.phone_disabled_rounded);
    expect(icon.color, AppColors.grey500);
  });

  testWidgets('incoming unanswered calls render as missed calls', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildCallMessageScreen(
        _callMessage(
          outcome: ChatCallOutcome.noAnswer,
          senderId: '2',
          recipientId: '1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    Finder bubbleFinder = _incomingCallBubbleFinder();

    expect(
      find.descendant(of: bubbleFinder, matching: find.text('Missed Call')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bubbleFinder, matching: find.text('No Answer')),
      findsNothing,
    );

    Icon icon = tester.widget<Icon>(
      find.descendant(of: bubbleFinder, matching: find.byType(Icon)),
    );

    expect(icon.icon, Icons.phone_missed_rounded);
    expect(icon.color, AppColors.red500);

    await tester.pumpWidget(
      _buildCallMessageScreen(
        _callMessage(
          outcome: ChatCallOutcome.cancelled,
          senderId: '2',
          recipientId: '1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    bubbleFinder = _incomingCallBubbleFinder();

    expect(
      find.descendant(of: bubbleFinder, matching: find.text('Missed Call')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bubbleFinder, matching: find.text('Canceled')),
      findsNothing,
    );

    icon = tester.widget<Icon>(
      find.descendant(of: bubbleFinder, matching: find.byType(Icon)),
    );

    expect(icon.icon, Icons.phone_missed_rounded);
    expect(icon.color, AppColors.red500);
  });
}

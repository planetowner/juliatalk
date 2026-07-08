import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/juliatalk_preview_app.dart';

double _expectedLastLineCenterY(WidgetTester tester) {
  final Finder inputFinder = find.byKey(
    const ValueKey<String>('message-input'),
  );

  final TextField textField = tester.widget<TextField>(inputFinder);

  final TextStyle textStyle = textField.style!;

  final TextPainter textPainter = TextPainter(
    text: TextSpan(text: 'A', style: textStyle),
    textDirection: TextDirection.ltr,
  )..layout();

  final EdgeInsets contentPadding =
      (textField.decoration?.contentPadding ?? EdgeInsets.zero).resolve(
        TextDirection.ltr,
      );

  final double result =
      tester.getRect(inputFinder).bottom -
      contentPadding.bottom -
      (textPainter.preferredLineHeight / 2);

  textPainter.dispose();

  return result;
}

double _gapBetweenMessageAndComposer(
  WidgetTester tester, {
  required Finder messageFinder,
  required Finder composerFinder,
}) {
  return tester.getRect(composerFinder).top -
      tester.getRect(messageFinder).bottom;
}

// 목록을 실제 대화의 마지막 메시지가 보이는 맨 아래로 이동시킨다.
// 초기 화면은 맨 위(오래된 메시지)에서 시작하므로, 최신 메시지를
// 기준으로 검증하는 테스트는 먼저 이 헬퍼로 하단으로 내려가야 한다.
Future<void> _scrollChatToBottom(WidgetTester tester) async {
  await tester.drag(
    find.byKey(const ValueKey<String>('message-list')),
    const Offset(0, -4000),
  );
  await tester.pumpAndSettle();
}

Future<void> _showMessage(WidgetTester tester, Finder messageFinder) async {
  final Finder listFinder = find.byKey(const ValueKey<String>('message-list'));

  for (int attempt = 0; attempt < 20; attempt++) {
    if (messageFinder.evaluate().isNotEmpty) {
      await tester.ensureVisible(messageFinder);
      await tester.pumpAndSettle();
      return;
    }

    // 목록이 최신 위치에서 시작하므로 손가락을 아래로 움직여
    // 과거 메시지 방향으로 스크롤한다.
    await tester.drag(listFinder, const Offset(0, 300));
    await tester.pumpAndSettle();
  }

  throw TestFailure('Could not bring the requested message into view.');
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maximumPumps = 40,
}) async {
  for (int index = 0; index < maximumPumps; index++) {
    await tester.pump(const Duration(milliseconds: 40));

    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }

  throw TestFailure('Could not find the requested widget.');
}

double _messagePulseScaleX(WidgetTester tester, String messageId) {
  final Transform pulseTransform = tester.widget<Transform>(
    find.byKey(ValueKey<String>('message-pulse-$messageId')),
  );

  return pulseTransform.transform.storage[0];
}

ScrollPosition _messageListPosition(WidgetTester tester) {
  final Finder messageListFinder = find.byKey(
    const ValueKey<String>('message-list'),
  );

  final Finder scrollableFinder = find.descendant(
    of: messageListFinder,
    matching: find.byType(Scrollable),
  );

  final ScrollableState scrollableState = tester.state<ScrollableState>(
    scrollableFinder,
  );

  return scrollableState.position;
}

void main() {
  testWidgets('incoming message menu only shows copy and reply', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await _showMessage(tester, find.text('欧巴我快要登机了'));
    await tester.longPress(find.text('欧巴我快要登机了'));
    await tester.pumpAndSettle();

    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Reply'), findsOneWidget);
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Unsend'), findsNothing);
  });

  testWidgets('selected message stays above the dimmed chat screen', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    final Finder bubbleFinder = find.byKey(
      const ValueKey<String>('incoming-bubble-1'),
    );

    await _showMessage(tester, find.text('欧巴我快要登机了'));
    await tester.longPress(find.text('欧巴我快要登机了'));

    await tester.pump();
    await tester.pumpAndSettle();

    final Finder menuFinder = find.byKey(
      const ValueKey<String>('message-action-menu'),
    );

    final Finder selectedMessageFinder = find.byKey(
      const ValueKey<String>('selected-message-preview'),
    );

    expect(menuFinder, findsOneWidget);
    expect(selectedMessageFinder, findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);

    expect(
      find.byKey(const ValueKey<String>('message-action-spotlight')),
      findsNothing,
    );

    final Rect originalBubbleRect = tester.getRect(bubbleFinder);

    final Rect selectedMessageRect = tester.getRect(selectedMessageFinder);

    expect(selectedMessageRect.top, closeTo(originalBubbleRect.top, 0.01));

    expect(
      selectedMessageRect.bottom,
      closeTo(originalBubbleRect.bottom, 0.01),
    );

    expect(
      selectedMessageRect.left,
      closeTo(originalBubbleRect.left - 8, 0.01),
    );

    expect(
      selectedMessageRect.right,
      closeTo(originalBubbleRect.right + 8, 0.01),
    );

    expect(tester.getSize(menuFinder).width, closeTo(288, 0.01));

    expect(
      tester.getRect(menuFinder).top,
      greaterThan(originalBubbleRect.bottom),
    );

    expect(find.byIcon(Icons.copy_outlined), findsOneWidget);

    expect(find.byIcon(Icons.reply_rounded), findsOneWidget);
  });

  testWidgets('recent outgoing message menu shows all four actions', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await tester.longPress(find.text('더 번식 안 하고 너만 있는거면 내가 잘 키워줄게'));
    await tester.pumpAndSettle();

    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Reply'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Unsend'), findsOneWidget);
  });

  testWidgets('unsend removes the message without leaving a placeholder', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    const String message = '더 번식 안 하고 너만 있는거면 내가 잘 키워줄게';

    await tester.ensureVisible(find.text(message));
    await tester.pumpAndSettle();

    expect(find.text(message), findsOneWidget);

    await tester.longPress(find.text(message));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Unsend'));
    await tester.pumpAndSettle();

    expect(find.text(message), findsNothing);

    expect(find.text('Message was deleted'), findsNothing);
  });

  testWidgets('short tap translation still works after adding long press', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await _showMessage(tester, find.text('我等你继续说呢'));
    await tester.tap(find.text('我等你继续说呢'));
    await tester.pumpAndSettle();

    expect(find.text('네가 계속 말해주길 기다리고 있어.'), findsOneWidget);
  });

  testWidgets('replying to incoming message opens the focused reply composer', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await _showMessage(tester, find.text('欧巴我快要登机了'));
    await tester.longPress(find.text('欧巴我快要登机了'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('reply-composer')),
      findsOneWidget,
    );

    expect(find.text('Reply to Lia'), findsOneWidget);

    final Text previewText = tester.widget<Text>(
      find.byKey(const ValueKey<String>('reply-composer-preview')),
    );

    expect(previewText.data, '欧巴我快要登机了');

    final EditableText editableText = tester.widget<EditableText>(
      find.byType(EditableText),
    );

    expect(editableText.focusNode.hasFocus, isTrue);
  });

  testWidgets('replying to an outgoing message uses Reply to Me', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await _showMessage(tester, find.text('너는 계속 얘기해도 돼'));
    await tester.longPress(find.text('너는 계속 얘기해도 돼'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();

    expect(find.text('Reply to Me'), findsOneWidget);
  });

  testWidgets('reply composer can be cancelled', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await _showMessage(tester, find.text('欧巴我快要登机了'));
    await tester.longPress(find.text('欧巴我快要登机了'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('reply-cancel')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('reply-composer')), findsNothing);

    expect(find.text('Enter a message'), findsOneWidget);
  });

  testWidgets('sending a reply renders the quoted message in the bubble', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await _showMessage(tester, find.text('너는 계속 얘기해도 돼'));
    await tester.longPress(find.text('너는 계속 얘기해도 돼'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('message-input')),
      '1',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('message-send')));
    await tester.pumpAndSettle();

    final Finder replyBubble = find.byKey(
      const ValueKey<String>('reply-message-9'),
    );

    expect(replyBubble, findsOneWidget);

    expect(
      find.descendant(of: replyBubble, matching: find.text('Reply to Me')),
      findsOneWidget,
    );

    expect(
      find.descendant(of: replyBubble, matching: find.text('너는 계속 얘기해도 돼')),
      findsOneWidget,
    );

    expect(
      find.descendant(of: replyBubble, matching: find.text('1')),
      findsOneWidget,
    );

    expect(find.byKey(const ValueKey<String>('reply-composer')), findsNothing);
  });

  testWidgets('default composer shows attachment and voice without emoji', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('message-composer-default')),
      findsOneWidget,
    );

    expect(
      find.byKey(const ValueKey<String>('message-attachment')),
      findsOneWidget,
    );

    expect(find.byKey(const ValueKey<String>('message-voice')), findsOneWidget);

    expect(find.byKey(const ValueKey<String>('message-send')), findsNothing);

    expect(find.byIcon(Icons.emoji_emotions_outlined), findsNothing);
  });

  testWidgets('typing replaces the voice button with the send button', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('message-input')),
      'Hello',
    );

    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('message-voice')), findsNothing);

    expect(find.byKey(const ValueKey<String>('message-send')), findsOneWidget);

    expect(find.byIcon(Icons.emoji_emotions_outlined), findsNothing);
  });

  testWidgets(
    'reply composer uses a transparent input without extra action buttons',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));

      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });

      await tester.pumpWidget(const JuliaTalkPreviewApp());
      await tester.pumpAndSettle();

      await _showMessage(tester, find.text('欧巴我快要登机了'));
      await tester.longPress(find.text('欧巴我快要登机了'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Reply'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('reply-composer')),
        findsOneWidget,
      );

      expect(
        find.byKey(const ValueKey<String>('message-attachment')),
        findsNothing,
      );

      expect(find.byKey(const ValueKey<String>('message-voice')), findsNothing);

      expect(find.byKey(const ValueKey<String>('message-send')), findsNothing);

      expect(find.byIcon(Icons.emoji_emotions_outlined), findsNothing);

      final TextField textField = tester.widget<TextField>(
        find.byKey(const ValueKey<String>('message-input')),
      );

      expect(textField.decoration?.filled, isFalse);

      expect(textField.decoration?.fillColor, Colors.transparent);

      await tester.enterText(
        find.byKey(const ValueKey<String>('message-input')),
        'Reply',
      );

      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('message-send')),
        findsOneWidget,
      );
    },
  );

  testWidgets('default composer actions align with the final input line', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('message-input')),
      '첫째 줄\n둘째 줄\n셋째 줄\n넷째 줄',
    );

    await tester.pumpAndSettle();

    final Finder attachmentFinder = find.byKey(
      const ValueKey<String>('message-attachment'),
    );

    final Finder sendFinder = find.byKey(
      const ValueKey<String>('message-send'),
    );

    final double expectedCenterY = _expectedLastLineCenterY(tester);

    expect(
      tester.getCenter(attachmentFinder).dy,
      closeTo(expectedCenterY, 1.0),
    );

    expect(tester.getCenter(sendFinder).dy, closeTo(expectedCenterY, 1.0));

    final ClipRRect composer = tester.widget<ClipRRect>(
      find.byKey(const ValueKey<String>('message-composer-default')),
    );

    expect(composer.borderRadius, const BorderRadius.all(Radius.circular(28)));
  });

  testWidgets('reply send aligns with the final input line and cancel center', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await _showMessage(tester, find.text('欧巴我快要登机了'));
    await tester.longPress(find.text('欧巴我快要登机了'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('message-input')),
      '첫째 줄\n둘째 줄\n셋째 줄\n넷째 줄',
    );

    await tester.pumpAndSettle();

    final Finder cancelFinder = find.byKey(
      const ValueKey<String>('reply-cancel'),
    );

    final Finder sendFinder = find.byKey(
      const ValueKey<String>('message-send'),
    );

    expect(
      tester.getCenter(cancelFinder).dx,
      closeTo(tester.getCenter(sendFinder).dx, 0.01),
    );

    expect(
      tester.getCenter(sendFinder).dy,
      closeTo(_expectedLastLineCenterY(tester), 1.0),
    );
  });

  testWidgets('edit opens with the original content and no save action', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await _showMessage(tester, find.text('너는 계속 얘기해도 돼'));
    await tester.longPress(find.text('너는 계속 얘기해도 돼'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('edit-composer')), findsOneWidget);

    expect(find.byKey(const ValueKey<String>('reply-composer')), findsNothing);

    expect(find.text('Edit message'), findsOneWidget);

    final Text previewText = tester.widget<Text>(
      find.byKey(const ValueKey<String>('edit-composer-preview')),
    );

    expect(previewText.data, '너는 계속 얘기해도 돼');

    final TextField textField = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('message-input')),
    );

    expect(textField.controller?.text, '너는 계속 얘기해도 돼');

    final EditableText editableText = tester.widget<EditableText>(
      find.byType(EditableText),
    );

    expect(editableText.focusNode.hasFocus, isTrue);

    expect(find.byKey(const ValueKey<String>('edit-save')), findsNothing);
  });

  testWidgets('edit save aligns with the final input line and cancel center', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await _showMessage(tester, find.text('너는 계속 얘기해도 돼'));
    await tester.longPress(find.text('너는 계속 얘기해도 돼'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('message-input')),
      '첫째 줄\n둘째 줄\n셋째 줄\n넷째 줄',
    );

    await tester.pumpAndSettle();

    final Finder cancelFinder = find.byKey(
      const ValueKey<String>('edit-cancel'),
    );

    final Finder saveFinder = find.byKey(const ValueKey<String>('edit-save'));

    expect(
      tester.getCenter(cancelFinder).dx,
      closeTo(tester.getCenter(saveFinder).dx, 0.01),
    );

    expect(
      tester.getCenter(saveFinder).dy,
      closeTo(_expectedLastLineCenterY(tester), 1.0),
    );
  });

  testWidgets('cancelling edit keeps the original message', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await _showMessage(tester, find.text('너는 계속 얘기해도 돼'));
    await tester.longPress(find.text('너는 계속 얘기해도 돼'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('message-input')),
      '수정하지 않을 내용',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('edit-cancel')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('edit-composer')), findsNothing);

    expect(
      find.byKey(const ValueKey<String>('message-composer-default')),
      findsOneWidget,
    );

    expect(find.text('너는 계속 얘기해도 돼'), findsOneWidget);

    expect(find.text('수정하지 않을 내용'), findsNothing);

    expect(
      find.byKey(const ValueKey<String>('message-edited-8')),
      findsNothing,
    );

    final TextField textField = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('message-input')),
    );

    expect(textField.controller?.text, isEmpty);
  });

  testWidgets('saving edit updates the same message and marks it edited', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await _showMessage(tester, find.text('너는 계속 얘기해도 돼'));
    await tester.longPress(find.text('너는 계속 얘기해도 돼'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('message-input')),
      '너는 계속 말해도 돼',
    );
    await tester.pumpAndSettle();

    final State<StatefulWidget> editableStateBeforeSave = tester
        .state<State<StatefulWidget>>(find.byType(EditableText));

    await tester.tap(find.byKey(const ValueKey<String>('edit-save')));
    await tester.pumpAndSettle();

    expect(find.text('너는 계속 얘기해도 돼'), findsNothing);

    expect(find.text('너는 계속 말해도 돼'), findsOneWidget);

    expect(
      find.byKey(const ValueKey<String>('outgoing-bubble-8')),
      findsOneWidget,
    );

    expect(
      find.byKey(const ValueKey<String>('outgoing-bubble-9')),
      findsNothing,
    );

    expect(
      find.byKey(const ValueKey<String>('message-edited-8')),
      findsOneWidget,
    );

    expect(find.text('Edited'), findsOneWidget);

    expect(find.byKey(const ValueKey<String>('edit-composer')), findsNothing);

    expect(
      find.byKey(const ValueKey<String>('message-composer-default')),
      findsOneWidget,
    );

    final EditableText editableText = tester.widget<EditableText>(
      find.byType(EditableText),
    );

    expect(editableText.focusNode.hasFocus, isTrue);

    final State<StatefulWidget> editableStateAfterSave = tester
        .state<State<StatefulWidget>>(find.byType(EditableText));

    expect(editableStateAfterSave, same(editableStateBeforeSave));
  });

  testWidgets('editing a reply keeps its quoted message', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await _showMessage(tester, find.text('너는 계속 얘기해도 돼'));
    await tester.longPress(find.text('너는 계속 얘기해도 돼'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('message-input')),
      '1',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('message-send')));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('1'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('message-input')),
      '2',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('edit-save')));
    await tester.pumpAndSettle();

    final Finder replyBubble = find.byKey(
      const ValueKey<String>('reply-message-9'),
    );

    expect(replyBubble, findsOneWidget);

    expect(
      find.descendant(of: replyBubble, matching: find.text('너는 계속 얘기해도 돼')),
      findsOneWidget,
    );

    expect(
      find.descendant(of: replyBubble, matching: find.text('2')),
      findsOneWidget,
    );

    expect(
      find.byKey(const ValueKey<String>('message-edited-9')),
      findsOneWidget,
    );
  });

  testWidgets('edit title preview and editable text share the same left edge', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await _showMessage(tester, find.text('너는 계속 얘기해도 돼'));
    await tester.longPress(find.text('너는 계속 얘기해도 돼'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    final Finder titleFinder = find.byKey(
      const ValueKey<String>('edit-composer-title'),
    );

    final Finder previewFinder = find.byKey(
      const ValueKey<String>('edit-composer-preview'),
    );

    final Finder editableFinder = find.byType(EditableText);

    final double titleLeft = tester.getRect(titleFinder).left;

    expect(tester.getRect(previewFinder).left, closeTo(titleLeft, 0.01));

    expect(tester.getRect(editableFinder).left, closeTo(titleLeft, 0.01));
  });

  testWidgets('sending keeps focus and the newest message visible', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 600));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await _scrollChatToBottom(tester);

    await tester.enterText(
      find.byKey(const ValueKey<String>('message-input')),
      '새 메시지',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('message-send')));
    await tester.pumpAndSettle();

    final EditableText editableText = tester.widget<EditableText>(
      find.byType(EditableText),
    );

    expect(editableText.focusNode.hasFocus, isTrue);

    final Rect listRect = tester.getRect(
      find.byKey(const ValueKey<String>('message-list')),
    );

    final Rect newestBubbleRect = tester.getRect(
      find.byKey(const ValueKey<String>('outgoing-bubble-9')),
    );

    expect(newestBubbleRect.bottom, lessThanOrEqualTo(listRect.bottom + 0.01));
  });

  testWidgets('reply keeps the latest message above the composer', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 600));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await _showMessage(tester, find.text('너는 계속 얘기해도 돼'));
    await tester.pumpAndSettle();

    await _showMessage(tester, find.text('너는 계속 얘기해도 돼'));
    await tester.longPress(find.text('너는 계속 얘기해도 돼'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();

    final Finder latestMessageFinder = find.byKey(
      const ValueKey<String>('incoming-bubble-107'),
    );

    final Finder composerFinder = find.byKey(
      const ValueKey<String>('reply-composer'),
    );

    final Rect listRect = tester.getRect(
      find.byKey(const ValueKey<String>('message-list')),
    );

    expect(
      tester.getRect(latestMessageFinder).bottom,
      lessThanOrEqualTo(listRect.bottom + 0.01),
    );

    expect(
      _gapBetweenMessageAndComposer(
        tester,
        messageFinder: latestMessageFinder,
        composerFinder: composerFinder,
      ),
      closeTo(12, 1),
    );
  });

  testWidgets('growing a multiline composer keeps the newest message visible', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 600));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('message-input')),
      '첫 메시지',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('message-send')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('message-input')),
      '첫째 줄\n둘째 줄\n셋째 줄\n넷째 줄',
    );
    await tester.pumpAndSettle();

    final Rect listRect = tester.getRect(
      find.byKey(const ValueKey<String>('message-list')),
    );

    final Rect newestBubbleRect = tester.getRect(
      find.byKey(const ValueKey<String>('outgoing-bubble-9')),
    );

    expect(newestBubbleRect.bottom, lessThanOrEqualTo(listRect.bottom + 0.01));
  });

  testWidgets('tapping an empty chat area dismisses the keyboard', (
    WidgetTester tester,
  ) async {
    // 모든 메시지가 화면 안에 들어와 목록 하단에
    // 실제 빈 공간이 생기도록 충분히 높은 화면을 사용한다.
    await tester.binding.setSurfaceSize(const Size(420, 2600));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('message-input')));
    await tester.pump();

    EditableText editableText = tester.widget<EditableText>(
      find.byType(EditableText),
    );

    expect(editableText.focusNode.hasFocus, isTrue);

    final Rect tapAreaRect = tester.getRect(
      find.byKey(const ValueKey<String>('message-list-tap-area')),
    );

    await tester.tapAt(Offset(tapAreaRect.center.dx, tapAreaRect.bottom - 20));
    await tester.pump();

    editableText = tester.widget<EditableText>(find.byType(EditableText));

    expect(editableText.focusNode.hasFocus, isFalse);
  });

  testWidgets('dragging the message list dismisses the keyboard', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 600));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('message-input')));
    await tester.pump();

    await tester.drag(
      find.byKey(const ValueKey<String>('message-list')),
      const Offset(0, 120),
    );
    await tester.pumpAndSettle();

    final EditableText editableText = tester.widget<EditableText>(
      find.byType(EditableText),
    );

    expect(editableText.focusNode.hasFocus, isFalse);
  });

  testWidgets('reply always quotes the original incoming message', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await _showMessage(tester, find.text('我等你继续说呢'));
    await tester.tap(find.text('我等你继续说呢'));
    await tester.pumpAndSettle();

    expect(find.text('네가 계속 말해주길 기다리고 있어.'), findsOneWidget);

    await tester.longPress(find.text('네가 계속 말해주길 기다리고 있어.'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();

    final Text preview = tester.widget<Text>(
      find.byKey(const ValueKey<String>('reply-composer-preview')),
    );

    expect(preview.data, '我等你继续说呢');
  });

  testWidgets(
    'sending a reply returns to the default composer and keeps focus',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));

      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });

      await tester.pumpWidget(const JuliaTalkPreviewApp());
      await tester.pumpAndSettle();

      await _showMessage(tester, find.text('너는 계속 얘기해도 돼'));
      await tester.longPress(find.text('너는 계속 얘기해도 돼'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Reply'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey<String>('message-input')),
        '답장',
      );
      await tester.pumpAndSettle();

      final State<StatefulWidget> editableStateBeforeSend = tester
          .state<State<StatefulWidget>>(find.byType(EditableText));

      await tester.tap(find.byKey(const ValueKey<String>('message-send')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('reply-composer')),
        findsNothing,
      );

      expect(
        find.byKey(const ValueKey<String>('message-composer-default')),
        findsOneWidget,
      );

      final TextField textField = tester.widget<TextField>(
        find.byKey(const ValueKey<String>('message-input')),
      );

      expect(textField.controller?.text, isEmpty);

      final EditableText editableText = tester.widget<EditableText>(
        find.byType(EditableText),
      );

      expect(editableText.focusNode.hasFocus, isTrue);

      final State<StatefulWidget> editableStateAfterSend = tester
          .state<State<StatefulWidget>>(find.byType(EditableText));

      expect(editableStateAfterSend, same(editableStateBeforeSend));
    },
  );

  testWidgets('sending preserves a trailing blank line', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    const String messageContent = '첫번째줄\n두번째줄\n세번째줄\n';

    await tester.enterText(
      find.byKey(const ValueKey<String>('message-input')),
      messageContent,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('message-send')));
    await tester.pumpAndSettle();

    final Finder bubbleFinder = find.byKey(
      const ValueKey<String>('outgoing-bubble-9'),
    );

    final Finder exactMessageText = find.descendant(
      of: bubbleFinder,
      matching: find.byWidgetPredicate((Widget widget) {
        return widget is Text && widget.data == messageContent;
      }),
    );

    expect(exactMessageText, findsOneWidget);
  });

  testWidgets('editing can add and preserve a trailing blank line', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await _showMessage(tester, find.text('너는 계속 얘기해도 돼'));
    await tester.longPress(find.text('너는 계속 얘기해도 돼'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    const String updatedContent = '너는 계속 얘기해도 돼\n';

    await tester.enterText(
      find.byKey(const ValueKey<String>('message-input')),
      updatedContent,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('edit-save')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('edit-save')));
    await tester.pumpAndSettle();

    final Finder bubbleFinder = find.byKey(
      const ValueKey<String>('outgoing-bubble-8'),
    );

    final Finder exactMessageText = find.descendant(
      of: bubbleFinder,
      matching: find.byWidgetPredicate((Widget widget) {
        return widget is Text && widget.data == updatedContent;
      }),
    );

    expect(exactMessageText, findsOneWidget);

    final EditableText editableText = tester.widget<EditableText>(
      find.byType(EditableText),
    );

    expect(editableText.focusNode.hasFocus, isTrue);
  });

  testWidgets(
    'long pressing a message dismisses composer focus before opening actions',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));

      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });

      await tester.pumpWidget(const JuliaTalkPreviewApp());
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey<String>('message-input')),
        '작성 중인 메시지',
      );
      await tester.pumpAndSettle();

      await _showMessage(tester, find.text('너는 계속 얘기해도 돼'));
      await tester.longPress(find.text('너는 계속 얘기해도 돼'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('message-action-menu')),
        findsOneWidget,
      );

      final TextField textField = tester.widget<TextField>(
        find.byKey(const ValueKey<String>('message-input')),
      );

      expect(textField.controller?.text, '작성 중인 메시지');

      final EditableText editableText = tester.widget<EditableText>(
        find.byType(EditableText),
      );

      expect(editableText.focusNode.hasFocus, isFalse);
    },
  );

  testWidgets(
    'long pressing a message dismisses reply focus and preserves the draft',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));

      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });

      await tester.pumpWidget(const JuliaTalkPreviewApp());
      await tester.pumpAndSettle();

      await _showMessage(tester, find.text('欧巴我快要登机了'));
      await tester.longPress(find.text('欧巴我快要登机了'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Reply'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey<String>('message-input')),
        '작성 중인 답장',
      );
      await tester.pumpAndSettle();

      await _showMessage(tester, find.text('너는 계속 얘기해도 돼'));
      await tester.longPress(find.text('너는 계속 얘기해도 돼'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('message-action-menu')),
        findsOneWidget,
      );

      expect(
        find.byKey(const ValueKey<String>('reply-composer')),
        findsOneWidget,
      );

      final TextField textField = tester.widget<TextField>(
        find.byKey(const ValueKey<String>('message-input')),
      );

      expect(textField.controller?.text, '작성 중인 답장');

      final EditableText editableText = tester.widget<EditableText>(
        find.byType(EditableText),
      );

      expect(editableText.focusNode.hasFocus, isFalse);
    },
  );

  testWidgets(
    'long pressing a message dismisses edit focus and preserves the draft',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));

      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });

      await tester.pumpWidget(const JuliaTalkPreviewApp());
      await tester.pumpAndSettle();

      await _showMessage(tester, find.text('너는 계속 얘기해도 돼'));
      await tester.longPress(find.text('너는 계속 얘기해도 돼'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey<String>('message-input')),
        '수정 중인 메시지',
      );
      await tester.pumpAndSettle();

      await tester.longPress(
        find.descendant(
          of: find.byKey(const ValueKey<String>('outgoing-bubble-8')),
          matching: find.text('너는 계속 얘기해도 돼'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('message-action-menu')),
        findsOneWidget,
      );

      expect(
        find.byKey(const ValueKey<String>('edit-composer')),
        findsOneWidget,
      );

      final TextField textField = tester.widget<TextField>(
        find.byKey(const ValueKey<String>('message-input')),
      );

      expect(textField.controller?.text, '수정 중인 메시지');

      final EditableText editableText = tester.widget<EditableText>(
        find.byType(EditableText),
      );

      expect(editableText.focusNode.hasFocus, isFalse);
    },
  );

  testWidgets(
    'opening the composer keeps the latest message visible as the viewport shrinks',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));

      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });

      await tester.pumpWidget(const JuliaTalkPreviewApp());
      await tester.pumpAndSettle();

      await _scrollChatToBottom(tester);

      await tester.tap(find.byKey(const ValueKey<String>('message-input')));
      await tester.pump();

      // 키보드가 올라와 사용 가능한 화면 높이가 줄어든 상황을 재현한다.
      await tester.binding.setSurfaceSize(const Size(420, 600));
      await tester.pumpAndSettle();

      final EditableText editableText = tester.widget<EditableText>(
        find.byType(EditableText),
      );

      expect(editableText.focusNode.hasFocus, isTrue);

      final Rect listRect = tester.getRect(
        find.byKey(const ValueKey<String>('message-list')),
      );

      final Rect latestMessageRect = tester.getRect(
        find.byKey(const ValueKey<String>('incoming-bubble-107')),
      );

      expect(
        latestMessageRect.bottom,
        lessThanOrEqualTo(listRect.bottom + 0.01),
      );
    },
  );

  testWidgets('preview includes the July first sample conversation', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    expect(find.text('Wednesday, July 1, 2026'), findsOneWidget);

    expect(find.text('那如果有一天我变成虫子了 欧巴怎么办'), findsOneWidget);

    expect(find.text('🥺'), findsOneWidget);

    expect(find.text('알 낳을거야?'), findsOneWidget);

    expect(find.text('더 번식 안 하고 너만 있는거면 내가 잘 키워줄게'), findsOneWidget);

    expect(find.text('下蛋🥚？？'), findsOneWidget);

    expect(find.text('哈哈哈哈哈哈哈哈哈哈哈哈哈'), findsOneWidget);

    expect(
      find.text(
        '那可以放养吗 我不想被关进笼子里 '
        '还想和你抱抱睡觉觉 然后亲亲',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'default composer keeps the common gap below the latest message',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 600));

      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });

      await tester.pumpWidget(const JuliaTalkPreviewApp());
      await tester.pumpAndSettle();

      await _scrollChatToBottom(tester);

      await tester.tap(find.byKey(const ValueKey<String>('message-input')));
      await tester.pumpAndSettle();

      final double gap = _gapBetweenMessageAndComposer(
        tester,
        messageFinder: find.byKey(
          const ValueKey<String>('incoming-bubble-107'),
        ),
        composerFinder: find.byKey(
          const ValueKey<String>('message-composer-default'),
        ),
      );

      expect(gap, closeTo(12, 1));
    },
  );

  testWidgets('edit keeps the latest message above the composer', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 600));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await _showMessage(tester, find.text('너는 계속 얘기해도 돼'));
    await tester.pumpAndSettle();

    await _showMessage(tester, find.text('너는 계속 얘기해도 돼'));
    await tester.longPress(find.text('너는 계속 얘기해도 돼'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    final Finder latestMessageFinder = find.byKey(
      const ValueKey<String>('incoming-bubble-107'),
    );

    final Finder composerFinder = find.byKey(
      const ValueKey<String>('edit-composer'),
    );

    final Rect listRect = tester.getRect(
      find.byKey(const ValueKey<String>('message-list')),
    );

    expect(
      tester.getRect(latestMessageFinder).bottom,
      lessThanOrEqualTo(listRect.bottom + 0.01),
    );

    expect(
      _gapBetweenMessageAndComposer(
        tester,
        messageFinder: latestMessageFinder,
        composerFinder: composerFinder,
      ),
      closeTo(12, 1),
    );
  });

  testWidgets(
    'reply quote navigates to the original without translating it and can return',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));

      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });

      await tester.pumpWidget(const JuliaTalkPreviewApp());
      await tester.pumpAndSettle();

      final Finder originalMessageFinder = find.text('抱歉啦欧巴');

      await _showMessage(tester, originalMessageFinder);

      await tester.longPress(originalMessageFinder);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Reply'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey<String>('message-input')),
        'dd',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey<String>('message-send')));
      await tester.pumpAndSettle();

      final Finder replyBubbleFinder = find.byKey(
        const ValueKey<String>('reply-message-9'),
      );

      expect(replyBubbleFinder, findsOneWidget);

      final Finder quoteAreaFinder = find.byKey(
        const ValueKey<String>('reply-quote-area-9'),
      );

      expect(quoteAreaFinder, findsOneWidget);

      final ScrollPosition messageListPosition = _messageListPosition(tester);

      final double scrollOffsetBeforeQuoteTap = messageListPosition.pixels;

      await tester.tap(quoteAreaFinder);
      await tester.pump();

      final Finder backButtonFinder = find.byKey(
        const ValueKey<String>('back-to-reply-message'),
      );

      await _pumpUntilFound(tester, backButtonFinder);

      expect(
        find.byKey(const ValueKey<String>('incoming-bubble-5')),
        findsOneWidget,
      );

      final Rect messageListRect = tester.getRect(
        find.byKey(const ValueKey<String>('message-list')),
      );

      final Rect originalBubbleRect = tester.getRect(
        find.byKey(const ValueKey<String>('incoming-bubble-5')),
      );

      final double originalTopRatio =
          (originalBubbleRect.top - messageListRect.top) /
          messageListRect.height;

      // 상단에 딱 붙거나 중앙에 놓이는 것이 아니라,
      // 채팅 표시 영역의 상단 1/3 부근에 위치해야 한다.
      expect(originalTopRatio, inInclusiveRange(0.18, 0.38));

      // 원문 전체가 채팅 표시 영역 안에 있어야 한다.
      expect(
        originalBubbleRect.top,
        greaterThanOrEqualTo(messageListRect.top - 0.5),
      );

      expect(
        originalBubbleRect.bottom,
        lessThanOrEqualTo(messageListRect.bottom + 0.5),
      );

      expect(find.text('抱歉啦欧巴'), findsOneWidget);

      // 인용 영역 탭은 번역을 실행하지 않는다.
      expect(find.text('미안해, 오빠.'), findsNothing);

      expect(
        find.byKey(const ValueKey<String>('message-highlight-5')),
        findsOneWidget,
      );

      await tester.pump(const Duration(milliseconds: 45));

      // _pumpUntilFound에서 이미 약 한 프레임이 진행됐으므로
      // 이 시점은 확대 펄스의 정점 부근이다.
      expect(_messagePulseScaleX(tester, '5'), greaterThan(1.005));

      await tester.pump(const Duration(milliseconds: 420));

      expect(_messagePulseScaleX(tester, '5'), closeTo(1, 0.001));

      expect(
        find.byKey(const ValueKey<String>('message-highlight-5')),
        findsNothing,
      );

      expect(backButtonFinder, findsOneWidget);

      await tester.pumpAndSettle();

      await tester.tap(backButtonFinder);
      await tester.pump();

      final Finder returnedHighlightFinder = find.byKey(
        const ValueKey<String>('message-highlight-9'),
      );

      await _pumpUntilFound(tester, returnedHighlightFinder);

      await tester.pump(const Duration(milliseconds: 45));

      expect(_messagePulseScaleX(tester, '9'), greaterThan(1.005));

      await tester.pump(const Duration(milliseconds: 420));

      expect(_messagePulseScaleX(tester, '9'), closeTo(1, 0.001));

      expect(returnedHighlightFinder, findsNothing);

      expect(
        messageListPosition.pixels,
        closeTo(scrollOffsetBeforeQuoteTap, 0.5),
      );

      expect(
        find.byKey(const ValueKey<String>('reply-message-9')),
        findsOneWidget,
      );

      expect(
        find.byKey(const ValueKey<String>('back-to-reply-message')),
        findsNothing,
      );
    },
  );

  testWidgets('attachment button opens the five-action panel', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('attachment-panel')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey<String>('message-attachment')));
    await tester.pumpAndSettle();

    final Finder panelFinder = find.byKey(
      const ValueKey<String>('attachment-panel'),
    );

    expect(panelFinder, findsOneWidget);

    expect(tester.getSize(panelFinder).height, closeTo(302, 0.1));

    expect(find.text('Photo'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Call'), findsOneWidget);
    expect(find.text('File'), findsOneWidget);
    expect(find.text('Voice Memo'), findsOneWidget);

    expect(find.text('Location'), findsNothing);
    expect(find.text('Contacts'), findsNothing);
    expect(find.text('Scheduled Message'), findsNothing);
    expect(find.text('Capture'), findsNothing);
    expect(find.text('Events'), findsNothing);

    final EditableText editableText = tester.widget<EditableText>(
      find.byType(EditableText),
    );

    expect(editableText.focusNode.hasFocus, isFalse);
  });

  testWidgets('attachment panel and keyboard mode preserve the draft', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('message-input')),
      '작성 중인 메시지',
    );
    await tester.pump();

    EditableText editableText = tester.widget<EditableText>(
      find.byType(EditableText),
    );

    expect(editableText.focusNode.hasFocus, isTrue);

    await tester.tap(find.byKey(const ValueKey<String>('message-attachment')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('attachment-panel')),
      findsOneWidget,
    );

    editableText = tester.widget<EditableText>(find.byType(EditableText));

    expect(editableText.focusNode.hasFocus, isFalse);

    expect(editableText.controller.text, '작성 중인 메시지');

    // 첨부 패널 상태의 같은 버튼은 × 역할을 한다.
    await tester.tap(find.byKey(const ValueKey<String>('message-attachment')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('attachment-panel')),
      findsNothing,
    );

    editableText = tester.widget<EditableText>(find.byType(EditableText));

    expect(editableText.focusNode.hasFocus, isTrue);

    expect(editableText.controller.text, '작성 중인 메시지');
  });

  testWidgets('tapping the chat background closes the attachment panel', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 2600));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('message-attachment')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('attachment-panel')),
      findsOneWidget,
    );

    final Rect listRect = tester.getRect(
      find.byKey(const ValueKey<String>('message-list-tap-area')),
    );

    await tester.tapAt(Offset(listRect.center.dx, listRect.bottom - 20));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('attachment-panel')),
      findsNothing,
    );

    final EditableText editableText = tester.widget<EditableText>(
      find.byType(EditableText),
    );

    expect(editableText.focusNode.hasFocus, isFalse);
  });

  testWidgets('scrolling the conversation keeps the attachment panel open', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('message-attachment')));
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey<String>('message-list')),
      const Offset(0, 220),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('attachment-panel')),
      findsOneWidget,
    );
  });

  testWidgets(
    'long pressing a message closes the attachment panel before actions',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));

      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });

      await tester.pumpWidget(const JuliaTalkPreviewApp());
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('message-attachment')),
      );
      await tester.pumpAndSettle();

      await _showMessage(tester, find.text('더 번식 안 하고 너만 있는거면 내가 잘 키워줄게'));

      expect(
        find.byKey(const ValueKey<String>('attachment-panel')),
        findsOneWidget,
      );

      await tester.longPress(find.text('더 번식 안 하고 너만 있는거면 내가 잘 키워줄게'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('attachment-panel')),
        findsNothing,
      );

      expect(
        find.byKey(const ValueKey<String>('message-action-menu')),
        findsOneWidget,
      );
    },
  );

  testWidgets('reply navigation keeps the attachment panel open', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    await _showMessage(tester, find.text('抱歉啦欧巴'));

    await tester.longPress(find.text('抱歉啦欧巴'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('message-input')),
      'dd',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('message-send')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('message-attachment')));
    await tester.pumpAndSettle();

    await _scrollChatToBottom(tester);

    final Finder quoteAreaFinder = find.byKey(
      const ValueKey<String>('reply-quote-area-9'),
    );

    expect(quoteAreaFinder, findsOneWidget);

    await tester.tap(quoteAreaFinder);
    await tester.pump();

    await _pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('back-to-reply-message')),
    );

    expect(
      find.byKey(const ValueKey<String>('attachment-panel')),
      findsOneWidget,
    );

    expect(
      find.byKey(const ValueKey<String>('back-to-reply-message')),
      findsOneWidget,
    );
  });
}

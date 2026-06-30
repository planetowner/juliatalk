import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/main.dart';

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

    await tester.longPress(find.text('너는 계속 얘기해도 돼'));
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

    expect(find.text('너는 계속 얘기해도 돼'), findsOneWidget);

    await tester.longPress(find.text('너는 계속 얘기해도 돼'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unsend'));
    await tester.pumpAndSettle();

    expect(find.text('너는 계속 얘기해도 돼'), findsNothing);
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

  testWidgets('default composer buttons share the composer vertical center', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());
    await tester.pumpAndSettle();

    final Finder composerFinder = find.byKey(
      const ValueKey<String>('message-composer-default'),
    );

    final Finder attachmentFinder = find.byKey(
      const ValueKey<String>('message-attachment'),
    );

    final Finder voiceFinder = find.byKey(
      const ValueKey<String>('message-voice'),
    );

    final double composerCenterY = tester.getRect(composerFinder).center.dy;

    expect(
      tester.getCenter(attachmentFinder).dy,
      closeTo(composerCenterY, 0.01),
    );

    expect(tester.getCenter(voiceFinder).dy, closeTo(composerCenterY, 0.01));
  });

  testWidgets(
    'reply cancel and send buttons share the same horizontal center',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));

      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });

      await tester.pumpWidget(const JuliaTalkPreviewApp());
      await tester.pumpAndSettle();

      await tester.longPress(find.text('欧巴我快要登机了'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Reply'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey<String>('message-input')),
        'Reply',
      );

      await tester.pumpAndSettle();

      final Finder cancelFinder = find.byKey(
        const ValueKey<String>('reply-cancel'),
      );

      final Finder sendFinder = find.byKey(
        const ValueKey<String>('message-send'),
      );

      final Finder inputFinder = find.byKey(
        const ValueKey<String>('message-input'),
      );

      expect(
        tester.getCenter(cancelFinder).dx,
        closeTo(tester.getCenter(sendFinder).dx, 0.01),
      );

      expect(
        tester.getCenter(sendFinder).dy,
        closeTo(tester.getCenter(inputFinder).dy, 0.01),
      );
    },
  );
}

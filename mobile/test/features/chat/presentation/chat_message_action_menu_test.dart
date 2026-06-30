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
}

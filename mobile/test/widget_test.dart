import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/main.dart';

void main() {
  testWidgets('chat starts the date separator below the top bar', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());

    await tester.pumpAndSettle();

    expect(find.text('Tuesday, June 30, 2026'), findsOneWidget);

    expect(find.text('Today'), findsNothing);

    final Rect topBarRect = tester.getRect(
      find.byKey(const ValueKey<String>('chat-top-bar')),
    );

    final Rect dateSeparatorRect = tester.getRect(
      find.byKey(const ValueKey<String>('chat-date-separator')),
    );

    expect(dateSeparatorRect.top - topBarRect.bottom, closeTo(8, 0.01));
  });

  testWidgets('message text and seen receipt remain aligned', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(const JuliaTalkPreviewApp());

    await tester.pumpAndSettle();

    final double firstIncomingLeft = tester
        .getTopLeft(find.text('欧巴我快要登机了'))
        .dx;

    final double secondIncomingLeft = tester
        .getTopLeft(find.text('我等你继续说呢'))
        .dx;

    final double firstOutgoingRight = tester
        .getTopRight(find.text('알아 장난이야'))
        .dx;

    final double secondOutgoingRight = tester
        .getTopRight(find.text('타이밍이 웃겨서'))
        .dx;

    final double seenReceiptRight = tester
        .getTopRight(find.text('Seen just now'))
        .dx;

    expect(firstIncomingLeft, closeTo(secondIncomingLeft, 0.01));

    expect(firstOutgoingRight, closeTo(secondOutgoingRight, 0.01));

    expect(seenReceiptRight, closeTo(secondOutgoingRight, 0.01));
  });
}

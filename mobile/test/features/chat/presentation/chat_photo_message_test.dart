import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/features/chat/domain/chat_message.dart';
import 'package:juliatalk/features/chat/presentation/chat_conversation_view.dart';

final Uint8List _testPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB'
  'CAYAAAAfFcSJAAAADUlEQVR42mNk+M/w'
  'HwAEAQH/2p3KAAAAAElFTkSuQmCC',
);

Widget _buildPhotoMessageScreen(ChatMessage message) {
  return MaterialApp(
    home: ChatConversationView(initialMessages: <ChatMessage>[message]),
  );
}

ChatMessage _photoMessage({
  required String senderId,
  required String recipientId,
  int attachmentCount = 1,
}) {
  return ChatMessage(
    id: '1',
    senderId: senderId,
    recipientId: recipientId,
    content: '',
    createdAt: DateTime(2026, 7, 1, 12, 52),
    photoAttachments: List<ChatPhotoAttachment>.generate(
      attachmentCount,
      (int index) => ChatPhotoAttachment(
        assetId: 'photo-preview-$index',
        previewBytes: _testPng,
        width: 1200,
        height: 900,
      ),
    ),
  );
}

Finder _photoFinder(int index) {
  return find.byKey(
    ValueKey<String>('photo-message-photo-preview-$index-$index'),
  );
}

Rect _photoRect(WidgetTester tester, int index) {
  return tester.getRect(_photoFinder(index));
}

void main() {
  testWidgets('incoming photo messages render as incoming media bubbles', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildPhotoMessageScreen(_photoMessage(senderId: '2', recipientId: '1')),
    );
    await tester.pumpAndSettle();

    final Finder bubbleFinder = find.byKey(
      const ValueKey<String>('incoming-bubble-1'),
    );

    expect(bubbleFinder, findsOneWidget);
    expect(
      find.descendant(
        of: bubbleFinder,
        matching: find.byKey(
          const ValueKey<String>('photo-message-photo-preview-0-0'),
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: bubbleFinder,
        matching: find.byKey(const ValueKey<String>('original-message-1')),
      ),
      findsNothing,
    );

    await tester.tap(bubbleFinder);
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('outgoing photo messages keep the outgoing media bubble key', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildPhotoMessageScreen(_photoMessage(senderId: '1', recipientId: '2')),
    );
    await tester.pumpAndSettle();

    final Finder bubbleFinder = find.byKey(
      const ValueKey<String>('outgoing-bubble-1'),
    );

    expect(bubbleFinder, findsOneWidget);
    expect(
      find.descendant(
        of: bubbleFinder,
        matching: find.byKey(
          const ValueKey<String>('photo-message-photo-preview-0-0'),
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('tapping a photo opens the full-screen photo viewer', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildPhotoMessageScreen(_photoMessage(senderId: '1', recipientId: '2')),
    );
    await tester.pumpAndSettle();

    await tester.tap(_photoFinder(0));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('photo-viewer-image-photo-preview-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('photo-viewer-back')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('photo-viewer-download')),
      findsOneWidget,
    );
    expect(find.text('Me'), findsOneWidget);
    expect(find.text('Jul 1, 2026 at 12:52 PM'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('photo-viewer-counter')),
      findsNothing,
    );
  });

  testWidgets(
    'multi-photo viewer starts from tapped photo and swipes forward',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        _buildPhotoMessageScreen(
          _photoMessage(senderId: '1', recipientId: '2', attachmentCount: 3),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(_photoFinder(1));
      await tester.pumpAndSettle();

      expect(find.text('Number 2 out of 3'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey<String>('photo-viewer-image-photo-preview-1'),
        ),
        findsOneWidget,
      );

      await tester.drag(
        find.byKey(const ValueKey<String>('photo-viewer-page-view')),
        const Offset(-420, 0),
      );
      await tester.pumpAndSettle();

      expect(find.text('Number 3 out of 3'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey<String>('photo-viewer-image-photo-preview-2'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('photo viewer toggles controls and dismisses on vertical swipe', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildPhotoMessageScreen(_photoMessage(senderId: '1', recipientId: '2')),
    );
    await tester.pumpAndSettle();

    await tester.tap(_photoFinder(0));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('photo-viewer-image-photo-preview-0')),
    );
    await tester.pumpAndSettle();

    final AnimatedSlide hiddenTopBar = tester.widget<AnimatedSlide>(
      find.byKey(const ValueKey<String>('photo-viewer-top-bar')),
    );
    final AnimatedSlide hiddenBottomOverlay = tester.widget<AnimatedSlide>(
      find.byKey(const ValueKey<String>('photo-viewer-bottom-overlay')),
    );

    expect(hiddenTopBar.offset, const Offset(0, -1));
    expect(hiddenBottomOverlay.offset, const Offset(0, 1));

    await tester.drag(
      find.byKey(const ValueKey<String>('photo-viewer-page-view')),
      const Offset(0, -260),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('photo-viewer-download')),
      findsNothing,
    );
  });

  testWidgets('three-photo collage uses one large image beside two stacked', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildPhotoMessageScreen(
        _photoMessage(senderId: '1', recipientId: '2', attachmentCount: 3),
      ),
    );
    await tester.pumpAndSettle();

    final Rect first = _photoRect(tester, 0);
    final Rect second = _photoRect(tester, 1);
    final Rect third = _photoRect(tester, 2);

    expect(first.left, lessThan(second.left));
    expect(first.top, closeTo(second.top, 0.5));
    expect(second.left, closeTo(third.left, 0.5));
    expect(third.top, greaterThan(second.top));
    expect(first.height, greaterThan(second.height));
    expect(second.height, closeTo(third.height, 0.5));
  });

  testWidgets(
    'five-photo collage uses a three-photo row over a two-photo row',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        _buildPhotoMessageScreen(
          _photoMessage(senderId: '1', recipientId: '2', attachmentCount: 5),
        ),
      );
      await tester.pumpAndSettle();

      final Rect first = _photoRect(tester, 0);
      final Rect second = _photoRect(tester, 1);
      final Rect third = _photoRect(tester, 2);
      final Rect fourth = _photoRect(tester, 3);
      final Rect fifth = _photoRect(tester, 4);

      expect(first.top, closeTo(second.top, 0.5));
      expect(second.top, closeTo(third.top, 0.5));
      expect(first.left, lessThan(second.left));
      expect(second.left, lessThan(third.left));
      expect(fourth.top, greaterThan(first.top));
      expect(fourth.top, closeTo(fifth.top, 0.5));
      expect(fourth.left, lessThan(fifth.left));
      expect(fourth.width, greaterThan(first.width));
    },
  );

  testWidgets('ten-photo collage renders three, three, two, and two photos', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildPhotoMessageScreen(
        _photoMessage(senderId: '1', recipientId: '2', attachmentCount: 10),
      ),
    );
    await tester.pumpAndSettle();

    for (int index = 0; index < 10; index++) {
      expect(_photoFinder(index), findsOneWidget);
    }

    final Rect first = _photoRect(tester, 0);
    final Rect fourth = _photoRect(tester, 3);
    final Rect seventh = _photoRect(tester, 6);
    final Rect ninth = _photoRect(tester, 8);

    expect(_photoRect(tester, 1).top, closeTo(first.top, 0.5));
    expect(_photoRect(tester, 2).top, closeTo(first.top, 0.5));
    expect(_photoRect(tester, 4).top, closeTo(fourth.top, 0.5));
    expect(_photoRect(tester, 5).top, closeTo(fourth.top, 0.5));
    expect(_photoRect(tester, 7).top, closeTo(seventh.top, 0.5));
    expect(_photoRect(tester, 9).top, closeTo(ninth.top, 0.5));
    expect(fourth.top, greaterThan(first.top));
    expect(seventh.top, greaterThan(fourth.top));
    expect(ninth.top, greaterThan(seventh.top));
    expect(seventh.width, greaterThan(first.width));
  });
}

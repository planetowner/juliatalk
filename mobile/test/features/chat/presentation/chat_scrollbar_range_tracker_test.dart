import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/features/chat/presentation/chat_scrollbar_range_tracker.dart';

void main() {
  test('an inserted older page extends the stable range by message count', () {
    final ChatScrollbarRangeTracker tracker = ChatScrollbarRangeTracker();

    tracker.update(
      rawMinimumExtent: 0,
      rawMaximumExtent: 9000,
      rawPixels: 900,
      viewportDimension: 1000,
      messageCount: 100,
      hasMoreBefore: true,
      hasMoreAfter: false,
    );
    tracker.extend(
      messagesBefore: 100,
      messagesAfter: 0,
      totalMessageCount: 200,
    );

    final ChatScrollbarRangeSnapshot snapshot = tracker.update(
      rawMinimumExtent: -90000,
      rawMaximumExtent: 9000,
      rawPixels: 900,
      viewportDimension: 1000,
      messageCount: 200,
      hasMoreBefore: true,
      hasMoreAfter: false,
    );

    expect(snapshot.minimumExtent, -10000);
    expect(snapshot.maximumExtent, 9000);
    expect(snapshot.pixels, 900);
    expect(snapshot.scrollFraction, closeTo(10900 / 19000, 0.000001));
    expect(
      snapshot.scrollFraction,
      lessThan(0.75),
      reason:
          'A provisional lazy-sliver extent must not throw the thumb to the '
          'bottom of its track.',
    );
  });

  test('real drag deltas remain continuous across repeated older pages', () {
    final ChatScrollbarRangeTracker tracker = ChatScrollbarRangeTracker();

    tracker.update(
      rawMinimumExtent: 0,
      rawMaximumExtent: 9000,
      rawPixels: 900,
      viewportDimension: 1000,
      messageCount: 100,
      hasMoreBefore: true,
      hasMoreAfter: false,
    );
    tracker.extend(
      messagesBefore: 100,
      messagesAfter: 0,
      totalMessageCount: 200,
    );
    tracker.update(
      rawMinimumExtent: -90000,
      rawMaximumExtent: 9000,
      rawPixels: 900,
      viewportDimension: 1000,
      messageCount: 200,
      hasMoreBefore: true,
      hasMoreAfter: false,
    );

    final ChatScrollbarRangeSnapshot dragged = tracker.update(
      rawMinimumExtent: -76000,
      rawMaximumExtent: 9000,
      rawPixels: -8500,
      viewportDimension: 1000,
      messageCount: 200,
      hasMoreBefore: true,
      hasMoreAfter: false,
    );

    expect(dragged.pixels, -8500);
    expect(dragged.scrollFraction, closeTo(1500 / 19000, 0.000001));

    tracker.extend(
      messagesBefore: 100,
      messagesAfter: 0,
      totalMessageCount: 300,
    );
    final ChatScrollbarRangeSnapshot nextPage = tracker.update(
      rawMinimumExtent: -150000,
      rawMaximumExtent: 9000,
      rawPixels: -8500,
      viewportDimension: 1000,
      messageCount: 300,
      hasMoreBefore: true,
      hasMoreAfter: false,
    );

    expect(nextPage.minimumExtent, -20000);
    expect(nextPage.pixels, -8500);
    expect(nextPage.scrollFraction, closeTo(11500 / 29000, 0.000001));
    expect(nextPage.scrollFraction, lessThan(0.5));
  });

  test('the real final edge snaps to the stable final edge', () {
    final ChatScrollbarRangeTracker tracker = ChatScrollbarRangeTracker();

    tracker.update(
      rawMinimumExtent: 0,
      rawMaximumExtent: 9000,
      rawPixels: 1000,
      viewportDimension: 1000,
      messageCount: 100,
      hasMoreBefore: true,
      hasMoreAfter: false,
    );
    tracker.extend(
      messagesBefore: 100,
      messagesAfter: 0,
      totalMessageCount: 200,
    );

    final ChatScrollbarRangeSnapshot bottom = tracker.update(
      rawMinimumExtent: -80000,
      rawMaximumExtent: 13000,
      rawPixels: 13000,
      viewportDimension: 1000,
      messageCount: 200,
      hasMoreBefore: true,
      hasMoreAfter: false,
    );

    expect(bottom.pixels, bottom.maximumExtent);
    expect(bottom.scrollFraction, 1);
  });

  test('transient raw maximum estimates do not change bottom distance', () {
    final ChatScrollbarRangeTracker tracker = ChatScrollbarRangeTracker();

    tracker.update(
      rawMinimumExtent: 0,
      rawMaximumExtent: 9000,
      rawPixels: 7000,
      viewportDimension: 1000,
      messageCount: 100,
      hasMoreBefore: true,
      hasMoreAfter: false,
    );

    final ChatScrollbarRangeSnapshot snapshot = tracker.update(
      rawMinimumExtent: -90000,
      rawMaximumExtent: 7500,
      rawPixels: 7000,
      viewportDimension: 1000,
      messageCount: 200,
      hasMoreBefore: true,
      hasMoreAfter: false,
    );

    expect(7500 - 7000, lessThan(snapshot.viewportDimension));
    expect(snapshot.maximumExtent - snapshot.pixels, 2000);
    expect(
      snapshot.maximumExtent - snapshot.pixels,
      greaterThan(snapshot.viewportDimension),
      reason:
          'A lazy sliver maximum estimate must not hide a latest button that '
          'is already more than one screen from the bottom.',
    );
  });

  test('equal history pages follow the measured KakaoTalk thumb stages', () {
    final ChatScrollbarRangeTracker tracker = ChatScrollbarRangeTracker();

    tracker.update(
      rawMinimumExtent: 0,
      rawMaximumExtent: 9000,
      rawPixels: 900,
      viewportDimension: 1000,
      messageCount: 100,
      hasMoreBefore: true,
      hasMoreAfter: false,
    );

    double resolvedLength() {
      return ChatScrollbarThumbLengthResolver.resolve(
        trackExtent: 600,
        proportionalLength: 20,
        messageCountScale: tracker.currentSnapshot!.messageCountScale,
      );
    }

    expect(resolvedLength(), 144);

    tracker.extend(
      messagesBefore: 100,
      messagesAfter: 0,
      totalMessageCount: 200,
    );
    expect(resolvedLength(), 72);

    tracker.extend(
      messagesBefore: 100,
      messagesAfter: 0,
      totalMessageCount: 300,
    );
    expect(resolvedLength(), 48);

    tracker.extend(
      messagesBefore: 100,
      messagesAfter: 0,
      totalMessageCount: 400,
    );
    expect(resolvedLength(), 36);

    tracker.extend(
      messagesBefore: 100,
      messagesAfter: 0,
      totalMessageCount: 500,
    );
    expect(resolvedLength(), 36);
  });
}

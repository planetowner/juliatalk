import 'dart:math' as math;

/// Keeps the chat scrollbar independent from transient lazy-sliver estimates.
///
/// A centered custom scroll view preserves the visible message when an older
/// page is inserted, but its raw minimum scroll extent can change by a very
/// large estimated amount until the newly inserted sliver has been measured.
/// This tracker follows real pixel deltas while extending its stable range by
/// the average extent of the messages that were already loaded.
final class ChatScrollbarRangeTracker {
  double? _minimumExtent;
  double? _maximumExtent;
  double? _pixels;
  double? _lastRawPixels;
  double _viewportDimension = 0;
  int _initialMessageCount = 0;
  int _messageCount = 0;

  bool get isInitialized =>
      _minimumExtent != null &&
      _maximumExtent != null &&
      _pixels != null &&
      _lastRawPixels != null;

  ChatScrollbarRangeSnapshot? get currentSnapshot {
    if (!isInitialized) {
      return null;
    }

    return ChatScrollbarRangeSnapshot(
      minimumExtent: _minimumExtent!,
      maximumExtent: _maximumExtent!,
      pixels: _pixels!,
      viewportDimension: _viewportDimension,
      messageCountScale: _messageCountScale,
    );
  }

  double get _messageCountScale {
    if (_initialMessageCount < 1 || _messageCount < 1) {
      return 1;
    }

    return math.max(1, _messageCount / _initialMessageCount);
  }

  void reset() {
    _minimumExtent = null;
    _maximumExtent = null;
    _pixels = null;
    _lastRawPixels = null;
    _viewportDimension = 0;
    _initialMessageCount = 0;
    _messageCount = 0;
  }

  /// Extends the stable range before Flutter lays out an inserted page.
  ///
  /// Using the existing average content extent makes equal-sized message pages
  /// occupy equal portions of the scrollbar. It also prevents an unmeasured
  /// lazy sliver's provisional extent from moving the thumb to an edge.
  void extend({
    required int messagesBefore,
    required int messagesAfter,
    required int totalMessageCount,
  }) {
    final int addedBefore = messagesBefore < 0 ? 0 : messagesBefore;
    final int addedAfter = messagesAfter < 0 ? 0 : messagesAfter;

    if (!isInitialized || addedBefore + addedAfter == 0) {
      _messageCount = totalMessageCount < 0 ? 0 : totalMessageCount;
      return;
    }

    final double minimumExtent = _minimumExtent!;
    final double maximumExtent = _maximumExtent!;
    final double scrollableExtent = math.max(
      0.0,
      maximumExtent - minimumExtent,
    );
    final int previousMessageCount = _messageCount < 1 ? 1 : _messageCount;
    final double estimatedContentExtent = math.max(
      _viewportDimension,
      scrollableExtent + _viewportDimension,
    );
    final double averageMessageExtent =
        estimatedContentExtent / previousMessageCount;

    _minimumExtent = minimumExtent - (averageMessageExtent * addedBefore);
    _maximumExtent = maximumExtent + (averageMessageExtent * addedAfter);
    _messageCount = totalMessageCount < 0 ? 0 : totalMessageCount;
  }

  /// Rebases the raw coordinate after a structural recenter that does not move
  /// the message visible on screen.
  void rebaseRawPixels(double rawPixels) {
    if (isInitialized && rawPixels.isFinite) {
      _lastRawPixels = rawPixels;
    }
  }

  ChatScrollbarRangeSnapshot update({
    required double rawMinimumExtent,
    required double rawMaximumExtent,
    required double rawPixels,
    required double viewportDimension,
    required int messageCount,
    required bool hasMoreBefore,
    required bool hasMoreAfter,
  }) {
    final bool hasValidRawMetrics =
        rawMinimumExtent.isFinite &&
        rawMaximumExtent.isFinite &&
        rawPixels.isFinite &&
        viewportDimension.isFinite &&
        rawMaximumExtent >= rawMinimumExtent &&
        viewportDimension >= 0;

    if (!hasValidRawMetrics) {
      reset();
      return const ChatScrollbarRangeSnapshot(
        minimumExtent: 0,
        maximumExtent: 0,
        pixels: 0,
        viewportDimension: 0,
        messageCountScale: 1,
      );
    }

    if (!isInitialized) {
      _minimumExtent = rawMinimumExtent;
      _maximumExtent = rawMaximumExtent;
      _pixels = rawPixels;
      _lastRawPixels = rawPixels;
      _viewportDimension = viewportDimension;
      _messageCount = messageCount < 0 ? 0 : messageCount;
      if (_messageCount > 0) {
        _initialMessageCount = _messageCount;
      }
    } else {
      final double rawDelta = rawPixels - _lastRawPixels!;

      _pixels = _pixels! + rawDelta;
      _lastRawPixels = rawPixels;
      _viewportDimension = viewportDimension;
      _messageCount = messageCount < 0 ? 0 : messageCount;
      if (_initialMessageCount < 1 && _messageCount > 0) {
        _initialMessageCount = _messageCount;
      }

      final double minimumExtent = _minimumExtent!;
      final double maximumExtent = _maximumExtent!;
      final bool rawOverscrollBefore = rawPixels < rawMinimumExtent;
      final bool rawOverscrollAfter = rawPixels > rawMaximumExtent;

      if (rawOverscrollBefore) {
        _pixels = minimumExtent + (rawPixels - rawMinimumExtent);
      } else if (rawOverscrollAfter) {
        _pixels = maximumExtent + (rawPixels - rawMaximumExtent);
      } else if (!hasMoreBefore && (rawPixels - rawMinimumExtent).abs() < 0.5) {
        _pixels = minimumExtent;
      } else if (!hasMoreAfter && (rawMaximumExtent - rawPixels).abs() < 0.5) {
        _pixels = maximumExtent;
      } else {
        _pixels = _pixels!.clamp(minimumExtent, maximumExtent).toDouble();
      }
    }

    return ChatScrollbarRangeSnapshot(
      minimumExtent: _minimumExtent!,
      maximumExtent: _maximumExtent!,
      pixels: _pixels!,
      viewportDimension: _viewportDimension,
      messageCountScale: _messageCountScale,
    );
  }
}

final class ChatScrollbarRangeSnapshot {
  const ChatScrollbarRangeSnapshot({
    required this.minimumExtent,
    required this.maximumExtent,
    required this.pixels,
    required this.viewportDimension,
    required this.messageCountScale,
  });

  final double minimumExtent;
  final double maximumExtent;
  final double pixels;
  final double viewportDimension;
  final double messageCountScale;

  double get scrollableExtent => math.max(0, maximumExtent - minimumExtent);

  double get scrollFraction {
    final double extent = scrollableExtent;

    if (extent <= 0) {
      return 0;
    }

    return ((pixels - minimumExtent) / extent).clamp(0.0, 1.0).toDouble();
  }
}

abstract final class ChatScrollbarThumbLengthResolver {
  // The reference scrollbar exposes one equal history window as 144 logical
  // pixels, then 72, 48, and the existing 36-pixel floor as pages accumulate.
  static const double minimumLength = 36;
  static const double initialPageLength = 144;

  static double resolve({
    required double trackExtent,
    required double proportionalLength,
    required double messageCountScale,
  }) {
    if (!trackExtent.isFinite || trackExtent <= 0) {
      return 0;
    }

    final double resolvedMinimum = math.min(minimumLength, trackExtent);
    final double resolvedProportional = proportionalLength
        .clamp(resolvedMinimum, trackExtent)
        .toDouble();
    final double resolvedScale =
        messageCountScale.isFinite && messageCountScale > 1
        ? messageCountScale
        : 1;
    final double pageScaledLength = (initialPageLength / resolvedScale)
        .clamp(resolvedMinimum, trackExtent)
        .toDouble();

    return math.max(resolvedProportional, pageScaledLength);
  }
}

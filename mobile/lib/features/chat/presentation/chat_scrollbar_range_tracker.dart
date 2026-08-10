import 'dart:math' as math;

/// lazy sliver의 일시적인 추정값과 분리된 채팅 스크롤 범위를 관리해요.
///
/// 이전 페이지를 넣으면 새 sliver를 측정하기 전까지 원시 범위가 크게 흔들릴 수 있어요.
/// 실제 픽셀 변화만 따라가고 기존 메시지의 평균 높이로 안정적인 범위를 미리 늘려요.
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

  /// Flutter가 새 페이지를 배치하기 전에 안정적인 범위를 늘려요.
  ///
  /// 기존 평균 높이를 써서 비슷한 메시지 페이지가 같은 비율을 차지하게 해요.
  /// 아직 측정하지 않은 sliver가 thumb를 끝으로 밀어내는 현상도 막아요.
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

  /// 화면의 메시지는 그대로 두고 구조를 가운데로 맞춘 뒤 원시 좌표 기준을 갱신해요.
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
  // 같은 크기의 대화 구간이 늘면 thumb를 144, 72, 48 순으로 줄이고 36에서 멈춰요.
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

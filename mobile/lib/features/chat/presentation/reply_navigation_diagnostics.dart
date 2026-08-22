import 'package:flutter/foundation.dart';

// 진단할 때는 dart:async와 flutter/services.dart import의 주석도 함께 풀어요.
// import 'dart:async';
// import 'package:flutter/services.dart';

abstract final class ReplyNavigationDiagnostics {
  static const int _maximumLineCount = 80;
  static final List<String> _lines = <String>[];
  static final Stopwatch _stopwatch = Stopwatch()..start();

  static void reset() {
    _lines.clear();
    _stopwatch
      ..reset()
      ..start();
  }

  static void record(String line) {
    final String elapsed = (_stopwatch.elapsedMicroseconds / 1000)
        .toStringAsFixed(1);
    final String timedLine = line.startsWith('[reply-navigation]')
        ? line.replaceFirst(
            '[reply-navigation]',
            '[reply-navigation +${elapsed}ms]',
          )
        : '[+${elapsed}ms] $line';

    if (_lines.length == _maximumLineCount) {
      _lines.removeAt(0);
    }

    _lines.add(timedLine);
    debugPrint(timedLine);
    // 진단할 때만 아래 줄의 주석을 풀어 클립보드 복사를 켜요.
    // unawaited(Clipboard.setData(ClipboardData(text: _lines.join('\n'))));
  }
}

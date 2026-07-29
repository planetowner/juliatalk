import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
    unawaited(Clipboard.setData(ClipboardData(text: _lines.join('\n'))));
  }
}

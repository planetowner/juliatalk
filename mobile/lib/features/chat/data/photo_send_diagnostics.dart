import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

final class ClipboardDiagnostics {
  ClipboardDiagnostics(this.logPrefix);

  final String logPrefix;
  final List<String> _lines = <String>[];

  void clear() {
    _lines.clear();
  }

  void record(String line) {
    _lines.add(line);
    debugPrint(line);
  }

  Future<void> copyToClipboard() async {
    final String text = _lines.join('\n');

    try {
      await Clipboard.setData(ClipboardData(text: text));
      debugPrint(
        '[$logPrefix] clipboard_copy_completed '
        'line_count=${_lines.length} '
        'character_count=${text.length}',
      );
    } on Object catch (error) {
      debugPrint('[$logPrefix] clipboard_copy_failed=$error');
    }
  }
}

final ClipboardDiagnostics _mediaSendDiagnostics = ClipboardDiagnostics(
  'media-send',
);

void beginMediaSendDiagnostics() {
  _mediaSendDiagnostics.clear();
}

void recordPhotoSendDiagnostic(String line) {
  _mediaSendDiagnostics.record(line);
}

Future<void> copyPhotoSendDiagnosticsToClipboard() async {
  await _mediaSendDiagnostics.copyToClipboard();
}

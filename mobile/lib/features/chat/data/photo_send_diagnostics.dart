import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

final List<String> _photoSendDiagnosticLines = <String>[];

void beginMediaSendDiagnostics() {
  _photoSendDiagnosticLines.clear();
}

void recordPhotoSendDiagnostic(String line) {
  _photoSendDiagnosticLines.add(line);
  debugPrint(line);
}

Future<void> copyPhotoSendDiagnosticsToClipboard() async {
  final String text = _photoSendDiagnosticLines.join('\n');

  try {
    await Clipboard.setData(ClipboardData(text: text));
    debugPrint(
      '[media-send] clipboard_copy_completed '
      'line_count=${_photoSendDiagnosticLines.length} '
      'character_count=${text.length}',
    );
  } on Object catch (error) {
    debugPrint('[media-send] clipboard_copy_failed=$error');
  }
}

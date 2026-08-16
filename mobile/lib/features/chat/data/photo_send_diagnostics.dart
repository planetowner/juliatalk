import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

final List<String> _photoSendDiagnosticLines = <String>[];

void recordPhotoSendDiagnostic(String line) {
  _photoSendDiagnosticLines.add(line);
  debugPrint(line);
}

Future<void> copyPhotoSendDiagnosticsToClipboard() async {
  final String text = _photoSendDiagnosticLines.join('\n');

  try {
    await Clipboard.setData(ClipboardData(text: text));
  } on PlatformException catch (error) {
    debugPrint('[photo-send] clipboard_copy_failed=$error');
  }
}

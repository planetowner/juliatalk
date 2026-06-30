import 'package:flutter/material.dart';

import 'design_system/app_theme.dart';
import 'features/chat/presentation/chat_style_preview_screen.dart';

void main() {
  runApp(const JuliaTalkPreviewApp());
}

final class JuliaTalkPreviewApp extends StatelessWidget {
  const JuliaTalkPreviewApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JuliaTalk',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: const ChatStylePreviewScreen(),
    );
  }
}

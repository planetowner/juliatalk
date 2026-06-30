import 'package:flutter/material.dart';

final class AppColors {
  AppColors._();

  // Neutral utility colors
  static const Color white = Color(0xFFFFFFFF);
  static const Color black = Color(0xFF000000);

  // Grey
  static const Color grey50 = Color(0xFFF9FAFB);
  static const Color grey100 = Color(0xFFF2F4F6);
  static const Color grey200 = Color(0xFFE5E8EB);
  static const Color grey300 = Color(0xFFD1D6DB);
  static const Color grey400 = Color(0xFFB0B8C1);
  static const Color grey500 = Color(0xFF8B95A1);
  static const Color grey600 = Color(0xFF6B7684);
  static const Color grey700 = Color(0xFF4E5968);
  static const Color grey800 = Color(0xFF333D4B);
  static const Color grey900 = Color(0xFF191F28);

  // Blue
  static const Color blue50 = Color(0xFFE8F3FF);
  static const Color blue100 = Color(0xFFC9E2FF);
  static const Color blue200 = Color(0xFF90C2FF);
  static const Color blue300 = Color(0xFF64A8FF);
  static const Color blue400 = Color(0xFF4593FC);
  static const Color blue500 = Color(0xFF3182F6);
  static const Color blue600 = Color(0xFF2272EB);
  static const Color blue700 = Color(0xFF1B64DA);
  static const Color blue800 = Color(0xFF1957C2);
  static const Color blue900 = Color(0xFF194AA6);

  // Red
  static const Color red50 = Color(0xFFFFEEEE);
  static const Color red100 = Color(0xFFFFD4D6);
  static const Color red200 = Color(0xFFFEAFB4);
  static const Color red300 = Color(0xFFFB8890);
  static const Color red400 = Color(0xFFF66570);
  static const Color red500 = Color(0xFFF04452);
  static const Color red600 = Color(0xFFE42939);
  static const Color red700 = Color(0xFFD22030);
  static const Color red800 = Color(0xFFBC1B2A);
  static const Color red900 = Color(0xFFA51926);

  // Green
  static const Color green50 = Color(0xFFF0FAF6);
  static const Color green100 = Color(0xFFAEEFD5);
  static const Color green200 = Color(0xFF76E4B8);
  static const Color green300 = Color(0xFF3FD599);
  static const Color green400 = Color(0xFF15C47E);
  static const Color green500 = Color(0xFF03B26C);
  static const Color green600 = Color(0xFF02A262);
  static const Color green700 = Color(0xFF029359);
  static const Color green800 = Color(0xFF028450);
  static const Color green900 = Color(0xFF027648);

  // JuliaTalk semantic colors
  static const Color background = white;
  static const Color backgroundSecondary = grey100;
  static const Color surface = white;

  static const Color textPrimary = grey900;
  static const Color textSecondary = grey600;
  static const Color textTertiary = grey500;
  static const Color textDisabled = grey400;
  static const Color textOnPrimary = white;

  static const Color border = grey200;
  static const Color divider = grey200;

  static const Color primary = blue500;
  static const Color primaryPressed = blue600;
  static const Color primaryMuted = blue50;

  static const Color success = green500;
  static const Color successMuted = green50;

  static const Color error = red500;
  static const Color errorMuted = red50;

  static const Color incomingMessageBubble = grey100;
  static const Color outgoingMessageBubble = blue500;
}

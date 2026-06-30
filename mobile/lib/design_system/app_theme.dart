import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_radius.dart';
import 'app_spacing.dart';
import 'app_typography.dart';

final class AppTheme {
  AppTheme._();

  static final ColorScheme _lightColorScheme =
      ColorScheme.fromSeed(
        seedColor: AppColors.primary,
        brightness: Brightness.light,
      ).copyWith(
        primary: AppColors.primary,
        onPrimary: AppColors.textOnPrimary,
        primaryContainer: AppColors.primaryMuted,
        onPrimaryContainer: AppColors.blue900,
        secondary: AppColors.blue600,
        onSecondary: AppColors.white,
        secondaryContainer: AppColors.blue50,
        onSecondaryContainer: AppColors.blue900,
        error: AppColors.error,
        onError: AppColors.white,
        errorContainer: AppColors.errorMuted,
        onErrorContainer: AppColors.red900,
        surface: AppColors.surface,
        onSurface: AppColors.textPrimary,
        surfaceContainerLowest: AppColors.white,
        surfaceContainerLow: AppColors.grey50,
        surfaceContainer: AppColors.grey100,
        surfaceContainerHigh: AppColors.grey100,
        surfaceContainerHighest: AppColors.grey200,
        onSurfaceVariant: AppColors.textSecondary,
        outline: AppColors.border,
        outlineVariant: AppColors.divider,
        shadow: AppColors.black,
        scrim: AppColors.black,
        surfaceTint: Colors.transparent,
      );

  static final TextTheme _textTheme = TextTheme(
    displayLarge: AppTypography.typography1.copyWith(
      color: AppColors.textPrimary,
      fontWeight: AppTypography.bold,
    ),
    displayMedium: AppTypography.typography2.copyWith(
      color: AppColors.textPrimary,
      fontWeight: AppTypography.bold,
    ),
    displaySmall: AppTypography.typography3.copyWith(
      color: AppColors.textPrimary,
      fontWeight: AppTypography.bold,
    ),
    headlineLarge: AppTypography.subTypography5.copyWith(
      color: AppColors.textPrimary,
      fontWeight: AppTypography.bold,
    ),
    headlineMedium: AppTypography.typography3.copyWith(
      color: AppColors.textPrimary,
      fontWeight: AppTypography.semibold,
    ),
    headlineSmall: AppTypography.typography4.copyWith(
      color: AppColors.textPrimary,
      fontWeight: AppTypography.semibold,
    ),
    titleLarge: AppTypography.subTypography9.copyWith(
      color: AppColors.textPrimary,
      fontWeight: AppTypography.semibold,
    ),
    titleMedium: AppTypography.typography5.copyWith(
      color: AppColors.textPrimary,
      fontWeight: AppTypography.semibold,
    ),
    titleSmall: AppTypography.subTypography10.copyWith(
      color: AppColors.textPrimary,
      fontWeight: AppTypography.medium,
    ),
    bodyLarge: AppTypography.typography5.copyWith(color: AppColors.textPrimary),
    bodyMedium: AppTypography.subTypography10.copyWith(
      color: AppColors.textPrimary,
    ),
    bodySmall: AppTypography.typography6.copyWith(
      color: AppColors.textSecondary,
    ),
    labelLarge: AppTypography.typography6.copyWith(
      color: AppColors.textPrimary,
      fontWeight: AppTypography.semibold,
    ),
    labelMedium: AppTypography.subTypography11.copyWith(
      color: AppColors.textSecondary,
      fontWeight: AppTypography.medium,
    ),
    labelSmall: AppTypography.typography7.copyWith(
      color: AppColors.textTertiary,
      fontWeight: AppTypography.medium,
    ),
  );

  static ThemeData get light {
    final ThemeData baseTheme = ThemeData.from(
      colorScheme: _lightColorScheme,
      textTheme: _textTheme,
      useMaterial3: true,
    );

    return baseTheme.copyWith(
      scaffoldBackgroundColor: AppColors.background,
      canvasColor: AppColors.background,
      dividerColor: AppColors.divider,
      appBarTheme: AppBarThemeData(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: AppSpacing.space20,
        titleTextStyle: AppTypography.typography4.copyWith(
          color: AppColors.textPrimary,
          fontWeight: AppTypography.semibold,
        ),
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
        actionsIconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: AppColors.grey100,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.space16,
          vertical: AppSpacing.space16,
        ),
        hintStyle: AppTypography.subTypography10.copyWith(
          color: AppColors.textTertiary,
        ),
        labelStyle: AppTypography.subTypography10.copyWith(
          color: AppColors.textSecondary,
        ),
        errorStyle: AppTypography.typography7.copyWith(color: AppColors.error),
        prefixIconColor: AppColors.textSecondary,
        suffixIconColor: AppColors.textSecondary,
        border: const OutlineInputBorder(
          borderRadius: AppRadius.borderRadius16,
          borderSide: BorderSide.none,
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: AppRadius.borderRadius16,
          borderSide: BorderSide.none,
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: AppRadius.borderRadius16,
          borderSide: BorderSide(color: AppColors.primary, width: 1.5),
        ),
        errorBorder: const OutlineInputBorder(
          borderRadius: AppRadius.borderRadius16,
          borderSide: BorderSide(color: AppColors.error),
        ),
        focusedErrorBorder: const OutlineInputBorder(
          borderRadius: AppRadius.borderRadius16,
          borderSide: BorderSide(color: AppColors.error, width: 1.5),
        ),
        disabledBorder: const OutlineInputBorder(
          borderRadius: AppRadius.borderRadius16,
          borderSide: BorderSide.none,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.textOnPrimary,
          disabledBackgroundColor: AppColors.grey200,
          disabledForegroundColor: AppColors.textDisabled,
          minimumSize: const Size(0, 56),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.space20,
            vertical: AppSpacing.space16,
          ),
          elevation: 0,
          textStyle: AppTypography.typography6.copyWith(
            fontWeight: AppTypography.semibold,
          ),
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.borderRadius16,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          disabledForegroundColor: AppColors.textDisabled,
          minimumSize: const Size(0, 56),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.space20,
            vertical: AppSpacing.space16,
          ),
          side: const BorderSide(color: AppColors.border),
          textStyle: AppTypography.typography6.copyWith(
            fontWeight: AppTypography.semibold,
          ),
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.borderRadius16,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primary,
          disabledForegroundColor: AppColors.textDisabled,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.space12,
            vertical: AppSpacing.space8,
          ),
          textStyle: AppTypography.typography6.copyWith(
            fontWeight: AppTypography.semibold,
          ),
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.borderRadius12,
          ),
        ),
      ),
      cardTheme: const CardThemeData(
        color: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.borderRadius16,
          side: BorderSide(color: AppColors.border),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.divider,
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.grey900,
        contentTextStyle: AppTypography.typography6.copyWith(
          color: AppColors.white,
        ),
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadius.borderRadius12,
        ),
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: AppColors.primary,
        selectionColor: AppColors.blue100,
        selectionHandleColor: AppColors.primary,
      ),
    );
  }
}

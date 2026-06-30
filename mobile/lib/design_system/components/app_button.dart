import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../app_spacing.dart';

final class AppButton extends StatelessWidget {
  const AppButton({
    required this.label,
    required this.onPressed,
    this.leading,
    this.isLoading = false,
    this.expand = true,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final Widget? leading;
  final bool isLoading;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final bool isEnabled = onPressed != null && !isLoading;

    return Semantics(
      button: true,
      enabled: isEnabled,
      child: SizedBox(
        width: expand ? double.infinity : null,
        child: FilledButton(
          onPressed: isEnabled ? onPressed : null,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: isLoading
                ? const SizedBox.square(
                    key: ValueKey<String>('loading'),
                    dimension: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.textOnPrimary,
                    ),
                  )
                : Row(
                    key: const ValueKey<String>('content'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (leading != null) ...[
                        leading!,
                        const SizedBox(width: AppSpacing.space8),
                      ],
                      Text(label),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

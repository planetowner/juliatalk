import 'package:flutter/material.dart';

import '../app_colors.dart';

final class AppProfileImage extends StatelessWidget {
  const AppProfileImage({
    required this.imageUrl,
    required this.size,
    required this.borderRadius,
    required this.iconSize,
    this.iconColor = AppColors.white,
    super.key,
  });

  final String? imageUrl;
  final double size;
  final double borderRadius;
  final double iconSize;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    final String? resolvedImageUrl = imageUrl?.trim();
    final BorderRadius radius = BorderRadius.circular(borderRadius);
    final Widget fallback = DecoratedBox(
      decoration: BoxDecoration(color: AppColors.blue100, borderRadius: radius),
      child: Icon(Icons.person_rounded, color: iconColor, size: iconSize),
    );

    return SizedBox.square(
      dimension: size,
      child: resolvedImageUrl == null || resolvedImageUrl.isEmpty
          ? fallback
          : ClipRRect(
              borderRadius: radius,
              child: Image.network(
                resolvedImageUrl,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => fallback,
              ),
            ),
    );
  }
}

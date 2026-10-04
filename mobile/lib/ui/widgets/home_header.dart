/// The compact brand header used on the Home.
///
/// The logo sits at the top of the screen, with the brand signature directly
/// under it; the user's avatar stays on the right as the entry point to the
/// profile tab. The shell leaves the Home app bar untitled, so the brand appears
/// exactly once — no second app bar, no duplicate title.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'brand_mark.dart';

class HomeHeader extends StatelessWidget {
  const HomeHeader({
    super.key,
    required this.greetingName,
    required this.onOpenProfile,
    this.subtitle = 'Vérification de compte',
  });

  /// First name shown on the avatar when there is no picture.
  final String greetingName;
  final VoidCallback onOpenProfile;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The logo sits at the very top of the screen; the signature
              // follows directly under it.
              const BrandMark(height: 40, asset: kHomeLogoAsset),
              const SizedBox(height: 6),
              Text(
                'Tango KYC',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                ),
              ),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        _ProfileAvatar(
          label: greetingName,
          onTap: onOpenProfile,
        ),
      ],
    );
  }
}

/// A circular avatar that opens the profile. Shows the user's initial, or a
/// neutral glyph when no name is available yet.
class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final initial = label.trim().isEmpty ? null : label.trim()[0].toUpperCase();

    return Semantics(
      button: true,
      label: 'Ouvrir le profil',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Padding(
            // Keeps the circular target at 48dp even though the disc is 40dp.
            padding: const EdgeInsets.all(4),
            child: Container(
              height: 40,
              width: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.primary.withValues(alpha: 0.16),
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.45),
                ),
              ),
              child: initial == null
                  ? Icon(Icons.person_outline_rounded, size: 20, color: scheme.primary)
                  : Text(
                      initial,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

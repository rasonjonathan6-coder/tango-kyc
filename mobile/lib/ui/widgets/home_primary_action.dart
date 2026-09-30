/// The primary Home action, extracted from `home_screen.dart` so the screen
/// stays a composition rather than a monolith.
///
/// This is the single visually dominant element after sign-in: it answers
/// "what can I do here?" with one obvious action. Everything else on the Home
/// is deliberately lighter than this card.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'aurora.dart';

/// The dominant "Demander une re-vérification" surface.
///
/// The whole card is the tap target, so the affordance is the card itself and
/// not a small button inside it: the primary action is reachable anywhere on the
/// surface, which keeps the touch area far above the 48dp minimum.
class PrimaryActionCard extends StatelessWidget {
  const PrimaryActionCard({
    super.key,
    required this.title,
    required this.description,
    required this.ctaLabel,
    required this.onTap,
    this.icon = Icons.verified_user_rounded,
  });

  final String title;
  final String description;

  /// Label of the inline call to action. The whole card is tappable regardless.
  final String ctaLabel;
  final VoidCallback onTap;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return GlassCard(
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // The one saturated fill on the screen, so the primary
                    // action stays the brightest object without a loud banner.
                    Container(
                      height: 52,
                      width: 52,
                      decoration: BoxDecoration(
                        gradient: AppTheme.actionGradient,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: AppTheme.glow(
                          AppColors.rose,
                          opacity: isDark ? 0.35 : 0.22,
                          blur: 18,
                        ),
                      ),
                      child: Icon(icon, color: Colors.white, size: 26),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            description,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                // A restrained inline CTA: a filled pill that reads as the
                // action, sized to its label so it never competes with the card.
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 11,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: isDark ? 0.22 : 0.12),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      border: Border.all(
                        color: scheme.primary.withValues(alpha: 0.45),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Flexible, not a bare Text: the label must be able to
                        // shrink (and ellipsize) on a narrow canvas instead of
                        // forcing the pill past the card's own width.
                        Flexible(
                          child: Text(
                            ctaLabel,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: isDark ? Colors.white : scheme.primary,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          Icons.arrow_forward_rounded,
                          size: 18,
                          color: isDark ? Colors.white : scheme.primary,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

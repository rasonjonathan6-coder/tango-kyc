/// The Home empty state: no request is being tracked yet.
///
/// Kept short on purpose — one line of explanation and the action that resolves
/// it. It replaces the previous static "service status" card, which claimed a
/// live operational state that nothing actually verified.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'aurora.dart';

class NoActiveRequestCard extends StatelessWidget {
  const NoActiveRequestCard({super.key, required this.onStart});

  /// Opens the same re-verification flow as the primary card.
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return GlassCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                height: 40,
                width: 40,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(
                  Icons.inbox_outlined,
                  size: 20,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'Aucune demande active',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Vous n’avez aucune demande en cours de traitement.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          // A minimum 48dp tall target: accessible without a heavy button that
          // would rival the primary card above it.
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onStart,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 48),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                foregroundColor: scheme.primary,
              ),
              icon: const Icon(Icons.add_circle_outline_rounded, size: 20),
              label: const Text('Demander une re-vérification'),
            ),
          ),
        ],
      ),
    );
  }
}

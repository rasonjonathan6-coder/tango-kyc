/// "Langue" — shows the language the app is rendered in.
///
/// Reached from the profile list (reference artwork, screen 12). The interface
/// is French only and there is no localisation bundle, so rather than offer a
/// switch that would do nothing, the screen states the fact plainly.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/aurora.dart';
import '../widgets/common.dart';
import '../widgets/tango_scaffold.dart';

class LanguageScreen extends StatelessWidget {
  const LanguageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return TangoKycScaffold(
      appBar: AppBar(title: const Text('Langue')),
      body: ListView(
        padding: AppSpacing.page,
        children: [
          AnimatedEntry(
            child: GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Column(
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.language_rounded,
                      color: theme.colorScheme.primary,
                    ),
                    title: const Text('Français'),
                    subtitle: const Text('Langue de l’interface'),
                    trailing: Icon(
                      Icons.check_circle_rounded,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AnimatedEntry(
            delay: const Duration(milliseconds: 60),
            child: Text(
              'L’application est disponible en français uniquement. D’autres langues '
              'pourront être ajoutées ultérieurement.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "À propos" — what the app is and which build is running.
///
/// Reached from the profile list (reference artwork, screen 12). It reuses the
/// build label that already lives in the settings screen, so there is one source
/// of truth for the version.
library;

import 'package:flutter/material.dart';

import '../../config/app_config.dart';
import '../theme/app_theme.dart';
import '../widgets/brand_mark.dart';
import '../widgets/common.dart';
import '../widgets/tango_scaffold.dart';
import 'help_support_screen.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return TangoKycScaffold(
      appBar: AppBar(title: const Text('À propos')),
      body: ListView(
        padding: AppSpacing.page,
        children: [
          AnimatedEntry(
            child: Center(
              child: Column(
                children: [
                  const BrandMark(height: 72),
                  const SizedBox(height: 14),
                  Text(
                    'Tango KYC Verification',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          AnimatedEntry(
            delay: const Duration(milliseconds: 60),
            child: SummaryCard(
              title: 'Application',
              children: [
                const InfoRow(label: 'Version', value: '1.0.0'),
                InfoRow(
                  label: 'Serveur',
                  value:
                      Uri.tryParse(
                        AppConfig.isConfigured ? AppConfig.supabaseUrl : '',
                      )?.host ??
                      '-',
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AnimatedEntry(
            delay: const Duration(milliseconds: 90),
            child: Text(
              'Cette application permet de soumettre une demande de vérification '
              'd’identité (KYC) et de suivre son traitement avec le support.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          AnimatedEntry(
            delay: const Duration(milliseconds: 120),
            child: OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HelpSupportScreen()),
              ),
              icon: const Icon(Icons.help_outline_rounded, size: 18),
              label: const Text('Aide & support'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Settings: appearance, account actions and app information.
///
/// Rendered as a pushed route, so it owns its [Scaffold]: that is what provides
/// the back affordance and the page title (the previous version rendered a bare
/// [ListView] into the navigator, leaving the user with no way back).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/app_config.dart';
import '../../state/auth_controller.dart';
import '../../state/settings_controller.dart';
import '../widgets/aurora.dart';
import '../widgets/common.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final auth = context.watch<AuthController>();
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Paramètres')),
      body: AuroraBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 32),
          children: [
            SummaryCard(
              title: 'Apparence',
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: settings.themeMode == ThemeMode.dark,
                  onChanged: (value) => settings.setThemeMode(
                    value ? ThemeMode.dark : ThemeMode.light,
                  ),
                  secondary: Icon(
                    settings.themeMode == ThemeMode.dark
                        ? Icons.dark_mode_rounded
                        : Icons.light_mode_rounded,
                  ),
                  title: const Text('Mode sombre'),
                  subtitle: Text(
                    settings.themeMode == ThemeMode.system
                        ? 'Selon votre système'
                        : (settings.themeMode == ThemeMode.dark
                              ? 'Activé'
                              : 'Désactivé'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            SummaryCard(
              title: 'Compte',
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.mail_outline_rounded),
                  title: const Text('Email'),
                  subtitle: Text(
                    auth.profile?.email ?? auth.session?.user.email ?? '-',
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.badge_outlined),
                  title: const Text('Rôle'),
                  subtitle: Text(
                    (auth.profile?.role ?? 'user') == 'admin'
                        ? 'Administrateur'
                        : 'Utilisateur',
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => context.read<AuthController>().signOut(),
                  icon: const Icon(Icons.logout_rounded),
                  label: const Text('Se déconnecter'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                    side: BorderSide(
                      color: theme.colorScheme.error.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            SummaryCard(
              title: 'À propos',
              children: [
                const InfoRow(
                  label: 'Application',
                  value: 'Tango KYC Verification',
                ),
                const InfoRow(label: 'Version', value: '1.0.0'),
                InfoRow(
                  label: 'Backend',
                  value:
                      Uri.tryParse(
                        AppConfig.isConfigured ? AppConfig.supabaseUrl : '',
                      )?.host ??
                      '-',
                ),
                const SizedBox(height: 8),
                Text(
                  'Vos documents d’identité ne sont jamais téléversés depuis cette application. '
                  'Le support vous enverra un lien sécurisé lorsqu’une vérification manuelle '
                  'sera planifiée.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            if (Supabase.instance.client.auth.currentSession != null)
              Text(
                'Connecté en tant que ${auth.session?.user.id ?? ''}',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

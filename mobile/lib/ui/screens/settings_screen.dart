/// Settings: appearance, account actions and app information.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/app_config.dart';
import '../../state/auth_controller.dart';
import '../../state/settings_controller.dart';
import '../widgets/common.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final auth = context.watch<AuthController>();
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 32),
      children: [
        SummaryCard(
          title: 'Appearance',
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: settings.themeMode == ThemeMode.dark,
              onChanged: (value) =>
                  settings.setThemeMode(value ? ThemeMode.dark : ThemeMode.light),
              secondary: Icon(settings.themeMode == ThemeMode.dark
                  ? Icons.dark_mode_rounded
                  : Icons.light_mode_rounded),
              title: const Text('Dark mode'),
              subtitle: Text(
                settings.themeMode == ThemeMode.system
                    ? 'Following your system setting'
                    : (settings.themeMode == ThemeMode.dark ? 'On' : 'Off'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        SummaryCard(
          title: 'Account',
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.mail_outline_rounded),
              title: const Text('Email'),
              subtitle: Text(auth.profile?.email ?? auth.session?.user.email ?? '-'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.badge_outlined),
              title: const Text('Role'),
              subtitle: Text(auth.profile?.role ?? 'user'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => context.read<AuthController>().signOut(),
              icon: const Icon(Icons.logout_rounded),
              label: const Text('Sign out'),
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
                side: BorderSide(color: theme.colorScheme.error.withValues(alpha: 0.5)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        SummaryCard(
          title: 'About',
          children: [
            const InfoRow(label: 'Application', value: 'Tango KYC Verification'),
            const InfoRow(label: 'Version', value: '1.0.0'),
            InfoRow(
              label: 'Backend',
              value: Uri.tryParse(AppConfig.isConfigured ? AppConfig.supabaseUrl : '')?.host ?? '-',
            ),
            const SizedBox(height: 8),
            Text(
              'Your identity documents are never uploaded through this application. '
              'Support will send you a secure link when a manual review is scheduled.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 18),
        if (Supabase.instance.client.auth.currentSession != null)
          Text(
            'Signed in as ${auth.session?.user.id ?? ''}',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
      ],
    );
  }
}

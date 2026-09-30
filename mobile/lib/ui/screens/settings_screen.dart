/// Settings: appearance, account actions and app information.
///
/// Rendered as a pushed route, so it owns its [Scaffold]: that is what provides
/// the back affordance and the page title (the previous version rendered a bare
/// [ListView] into the navigator, leaving the user with no way back).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/app_config.dart';
import '../../services/notification_service.dart';
import '../../state/auth_controller.dart';
import '../../state/settings_controller.dart';
import '../widgets/common.dart';
import '../widgets/tango_scaffold.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, this.embedded = false});

  /// When true the screen is hosted as a bottom-navigation tab, so it must not
  /// draw its own app bar: the shell already provides one.
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final auth = context.watch<AuthController>();
    final theme = Theme.of(context);

    return TangoKycScaffold(
      appBar: embedded ? null : AppBar(title: const Text('Paramètres')),
      body: ListView(
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
            title: 'Notifications',
            children: const [_NotificationPermissionTile()],
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
                label: 'Serveur',
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
          if (auth.session != null)
            Text(
              'Connecté en tant que ${auth.session?.user.id ?? ''}',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

/// Shows and drives the real notification permission.
///
/// Reading the state never prompts; the switch is the only place that does, and
/// only while the platform still allows asking. On a device where Firebase is
/// unavailable the row says so instead of pretending.
class _NotificationPermissionTile extends StatefulWidget {
  const _NotificationPermissionTile();

  @override
  State<_NotificationPermissionTile> createState() =>
      _NotificationPermissionTileState();
}

class _NotificationPermissionTileState
    extends State<_NotificationPermissionTile> {
  NotificationPermission? _state;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _read();
  }

  PushService? _push() {
    try {
      return Provider.of<PushService>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  Future<void> _read() async {
    final push = _push();
    if (push == null) {
      if (mounted) setState(() => _state = NotificationPermission.unavailable);
      return;
    }
    final value = await push.notificationPermission();
    if (mounted) setState(() => _state = value);
  }

  Future<void> _toggle(bool value) async {
    final push = _push();
    if (push == null || !value) return;
    setState(() => _busy = true);
    final result = await push.requestNotificationPermission();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _state = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = _state;
    final granted = state == NotificationPermission.granted;
    final unavailable = state == NotificationPermission.unavailable;

    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: granted,
      onChanged: state == null || unavailable || _busy || granted
          ? null
          : _toggle,
      secondary: _busy
          ? const SizedBox(
              height: 22,
              width: 22,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            )
          : Icon(
              granted
                  ? Icons.notifications_active_rounded
                  : Icons.notifications_off_outlined,
            ),
      title: const Text('Alertes push'),
      subtitle: Text(
        switch (state) {
          null => 'Vérification…',
          NotificationPermission.granted => 'Activées sur cet appareil',
          NotificationPermission.denied =>
            'Désactivées. Touchez pour autoriser.',
          NotificationPermission.unavailable =>
            'Indisponibles sur cet appareil.',
        },
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

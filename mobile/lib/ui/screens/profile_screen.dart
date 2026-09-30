/// Profile: account identity, activity summary and the account actions.
///
/// The reference artwork shows a compact header (avatar, name, address, a
/// verification chip) followed by a plain list of rows. Those rows are wired to
/// the real destinations this app already had — settings, notifications, help —
/// plus the sign-out the previous version exposed as a button.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/auth_controller.dart';
import '../../state/kyc_controller.dart';
import '../../state/notifications_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/aurora.dart';
import '../widgets/common.dart';
import '../widgets/tango_scaffold.dart';
import 'about_screen.dart';
import 'account_info_screen.dart';
import 'help_support_screen.dart';
import 'language_screen.dart';
import 'notifications_screen.dart';
import 'security_screen.dart';
import 'settings_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key, this.embedded = false});

  /// When true the screen is hosted as a bottom-navigation tab, so it must not
  /// draw its own app bar: the shell already provides one. The screen otherwise
  /// behaves identically whether pushed or embedded.
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final kyc = context.watch<KycController>();
    final profile = auth.profile;
    final isAdmin = profile?.isAdmin ?? false;

    final replied = kyc.requests
        .where((r) => r.status.name == 'replied')
        .length;

    return TangoKycScaffold(
      appBar: embedded
          ? null
          : AppBar(
              title: const Text('Mon profil'),
              actions: [
                // The artwork's list has no "Paramètres" row (appearance, push
                // alerts). That screen is kept and reached from here, so the list
                // can match the artwork without losing a destination. When
                // embedded, Paramètres is its own tab and this action is omitted.
                IconButton(
                  tooltip: 'Paramètres',
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ),
                ),
              ],
            ),
      body: ListView(
        padding: AppSpacing.page,
        children: [
          AnimatedEntry(
            child: _ProfileHeader(
              name: profile?.displayName ?? 'Votre compte',
              email: profile?.email ?? auth.session?.user.email ?? '',
              initial: (profile?.greetingName ?? 'U').characters.first
                  .toUpperCase(),
              isAdmin: isAdmin,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          AnimatedEntry(
            delay: const Duration(milliseconds: 60),
            child: GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Column(
                children: [
                  _ProfileRow(
                    icon: Icons.confirmation_number_outlined,
                    label: 'Mes tickets',
                    value:
                        '${kyc.requests.where((r) => r.registerValue != 'WELCOME').length}',
                  ),
                  const Divider(height: 1),
                  _ProfileRow(
                    icon: Icons.mark_email_read_outlined,
                    label: 'Réponses reçues',
                    value: '$replied',
                  ),
                  const Divider(height: 1),
                  _ProfileRow(
                    icon: Icons.schedule_rounded,
                    label: 'Dernier ticket',
                    value: kyc.requests.isEmpty
                        ? 'Aucun'
                        : kyc.requests.first.ticketCode,
                    mono: true,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          AnimatedEntry(
            delay: const Duration(milliseconds: 110),
            child: GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Column(
                children: [
                  _ProfileRow(
                    icon: Icons.person_outline_rounded,
                    label: 'Mes informations',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const AccountInfoScreen(),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  _ProfileRow(
                    icon: Icons.lock_outline_rounded,
                    label: 'Sécurité',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SecurityScreen()),
                    ),
                  ),
                  const Divider(height: 1),
                  _ProfileRow(
                    icon: Icons.notifications_none_rounded,
                    label: 'Notifications',
                    trailing:
                        context.watch<NotificationsController>().unreadCount > 0
                        ? Badge.count(
                            count: context
                                .watch<NotificationsController>()
                                .unreadCount,
                          )
                        : null,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const NotificationsScreen(),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  _ProfileRow(
                    icon: Icons.language_rounded,
                    label: 'Langue',
                    value: 'Français',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const LanguageScreen()),
                    ),
                  ),
                  const Divider(height: 1),
                  _ProfileRow(
                    icon: Icons.help_outline_rounded,
                    label: 'Aide & support',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const HelpSupportScreen(),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  _ProfileRow(
                    icon: Icons.info_outline_rounded,
                    label: 'À propos',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const AboutScreen()),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Avatar, name, address and the role/verification chip.
class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({
    required this.name,
    required this.email,
    required this.initial,
    required this.isAdmin,
  });

  final String name;
  final String email;
  final String initial;
  final bool isAdmin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Container(
            height: 78,
            width: 78,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: AppTheme.actionGradient,
              shape: BoxShape.circle,
              boxShadow: AppTheme.glow(
                AppColors.violet,
                opacity: 0.45,
                blur: 22,
              ),
            ),
            child: Text(
              initial,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            name,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            email,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              gradient: isAdmin ? AppTheme.actionGradient : null,
              color: isAdmin ? null : scheme.primary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppRadius.pill),
              border: Border.all(
                color: isAdmin
                    ? Colors.transparent
                    : scheme.primary.withValues(alpha: 0.4),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isAdmin ? Icons.shield_rounded : Icons.person_rounded,
                  size: 14,
                  color: isAdmin ? Colors.white : scheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  isAdmin ? 'Administrateur vérifié' : 'Compte vérifié',
                  style: TextStyle(
                    color: isAdmin ? Colors.white : scheme.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One row of the profile list: icon, label, optional value, optional badge.
class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    required this.icon,
    required this.label,
    this.value,
    this.trailing,
    this.onTap,
    this.mono = false,
  });

  final IconData icon;
  final String label;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          Icon(icon, size: 20, color: scheme.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (value != null)
            Text(
              value!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                fontFeatures: mono
                    ? const [FontFeature.tabularFigures()]
                    : null,
              ),
            ),
          ?trailing,
          if (onTap != null) ...[
            const SizedBox(width: 6),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return row;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: row,
    );
  }
}

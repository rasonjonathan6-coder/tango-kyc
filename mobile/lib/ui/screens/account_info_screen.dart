/// "Mes informations" — the account identity, read-only.
///
/// Reached from the profile list (reference artwork, screen 12). Editing the
/// display name is not offered here: the profile row is written by a server-side
/// trigger and the app has no update path for it, so the screen shows the real
/// values without pretending they can be changed.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/auth_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/tango_scaffold.dart';

class AccountInfoScreen extends StatelessWidget {
  const AccountInfoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final profile = auth.profile;
    final email = profile?.email ?? auth.session?.user.email ?? '';
    final userId = auth.session?.user.id ?? '';

    return TangoKycScaffold(
      appBar: AppBar(title: const Text('Mes informations')),
      body: ListView(
        padding: AppSpacing.page,
        children: [
          AnimatedEntry(
            child: SummaryCard(
              title: 'Identité',
              children: [
                InfoRow(
                  label: 'Nom affiché',
                  value: profile?.displayName?.isNotEmpty == true
                      ? profile!.displayName!
                      : 'Non renseigné',
                ),
                InfoRow(
                  label: 'Email',
                  value: email.isEmpty ? 'Non disponible' : email,
                ),
                InfoRow(
                  label: 'Rôle',
                  value: profile?.isAdmin == true
                      ? 'Administrateur'
                      : 'Utilisateur',
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AnimatedEntry(
            delay: const Duration(milliseconds: 60),
            child: SummaryCard(
              title: 'Identifiant de connexion',
              children: [
                InfoRow(
                  label: 'Identifiant',
                  value: userId.isEmpty ? 'Non disponible' : userId,
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AnimatedEntry(
            delay: const Duration(milliseconds: 90),
            child: Text(
              'Ces informations proviennent de votre compte et ne peuvent pas être '
              'modifiées depuis l’application. Contactez le support pour toute '
              'correction.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

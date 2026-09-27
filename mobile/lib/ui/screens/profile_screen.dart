/// Profile: account identity, request summary and sign out.
///
/// Like settings, this is a pushed route and therefore owns its [Scaffold] so the
/// back affordance and title are present.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/auth_controller.dart';
import '../../state/kyc_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/aurora.dart';
import '../widgets/common.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final kyc = context.watch<KycController>();
    final theme = Theme.of(context);
    final profile = auth.profile;

    final replied = kyc.requests
        .where((r) => r.status.name == 'replied')
        .length;
    final isAdmin = profile?.isAdmin ?? false;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Profil')),
      body: AuroraBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 32),
          children: [
            AnimatedEntry(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Container(
                        height: 72,
                        width: 72,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          gradient: isAdmin
                              ? AppTheme.brandGradient
                              : LinearGradient(
                                  colors: [
                                    theme.colorScheme.primary.withValues(
                                      alpha: 0.9,
                                    ),
                                    theme.colorScheme.primary.withValues(
                                      alpha: 0.6,
                                    ),
                                  ],
                                ),
                          shape: BoxShape.circle,
                          boxShadow: AppTheme.glow(
                            AppColors.violet,
                            opacity: 0.4,
                            blur: 20,
                          ),
                        ),
                        child: Text(
                          (profile?.greetingName ?? 'U').characters.first
                              .toUpperCase(),
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        profile?.displayName ?? 'Votre compte',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        profile?.email ?? auth.session?.user.email ?? '',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Chip(
                        avatar: Icon(
                          isAdmin ? Icons.shield_rounded : Icons.person_rounded,
                          size: 16,
                        ),
                        label: Text(isAdmin ? 'ADMINISTRATEUR' : 'UTILISATEUR'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            SummaryCard(
              title: 'Activité',
              children: [
                InfoRow(label: 'Demandes', value: '${kyc.requests.length}'),
                InfoRow(label: 'Réponses reçues', value: '$replied'),
                InfoRow(
                  label: 'Dernier ticket',
                  value: kyc.requests.isEmpty
                      ? 'Aucun'
                      : kyc.requests.first.ticketCode,
                ),
              ],
            ),
            const SizedBox(height: 18),
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
      ),
    );
  }
}

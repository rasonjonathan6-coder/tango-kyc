/// Profile: account identity, request summary and sign out.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/auth_controller.dart';
import '../../state/kyc_controller.dart';
import '../widgets/common.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final kyc = context.watch<KycController>();
    final theme = Theme.of(context);
    final profile = auth.profile;

    final replied = kyc.requests.where((r) => r.status.name == 'replied').length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 32),
      children: [
        AnimatedEntry(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 34,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Text(
                      (profile?.greetingName ?? 'U').characters.first.toUpperCase(),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    profile?.displayName ?? 'Your account',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    profile?.email ?? auth.session?.user.email ?? '',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  Chip(
                    avatar: Icon(
                      profile?.isAdmin ?? false ? Icons.shield_rounded : Icons.person_rounded,
                      size: 16,
                    ),
                    label: Text((profile?.role ?? 'user').toUpperCase()),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        SummaryCard(
          title: 'Activity',
          children: [
            InfoRow(label: 'Requests', value: '${kyc.requests.length}'),
            InfoRow(label: 'Replies received', value: '$replied'),
            InfoRow(
              label: 'Latest ticket',
              value: kyc.requests.isEmpty ? 'None yet' : kyc.requests.first.ticketCode,
            ),
          ],
        ),
        const SizedBox(height: 18),
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
    );
  }
}

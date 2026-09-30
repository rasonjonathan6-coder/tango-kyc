/// Admin dashboard: volume metrics, the full ticket queue and the quarantine
/// queue for replies that could not be matched to a ticket with certainty.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/validators.dart';
import '../../models/models.dart';
import '../../state/admin_controller.dart';
import '../../state/auth_controller.dart';
import '../widgets/common.dart';
import '../widgets/tango_scaffold.dart';
import 'admin_mvola_screen.dart';
import 'admin_ticket_screen.dart';

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AdminController>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final admin = context.watch<AdminController>();
    final isAdmin = context.watch<AuthController>().isAdmin;
    final theme = Theme.of(context);

    if (!isAdmin) {
      return const TangoKycScaffold(
        body: EmptyState(
          icon: Icons.lock_outline_rounded,
          title: 'Accès administrateur requis',
          message: 'Votre compte n’a pas la permission de consulter ce tableau de bord.',
        ),
      );
    }

    return TangoKycScaffold(
      appBar: AppBar(title: const Text('Administration')),
      body: RefreshIndicator(
      onRefresh: () => admin.load(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 32),
        children: [
          Text(
            'Vue d’ensemble',
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          AnimatedEntry(child: _StatsGrid(stats: admin.stats)),
          const SizedBox(height: 14),
          AnimatedEntry(
            child: Card(
              child: ListTile(
                leading: const Icon(Icons.account_balance_wallet_rounded),
                title: const Text('Paiements MVola'),
                subtitle: const Text('Vérifier les transferts Mobile Money manuels'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AdminMvolaScreen()),
                ),
              ),
            ),
          ),
          if (admin.unmatched.isNotEmpty) ...[
            const SizedBox(height: 22),
            Text(
              'Réponses non attribuées',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Ces réponses n’ont pas pu être attribuées à un ticket avec certitude. '
              'Elles ne sont jamais transmises automatiquement à un utilisateur.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            for (final item in admin.unmatched)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _UnmatchedCard(item: item, tickets: admin.tickets),
              ),
          ],
          const SizedBox(height: 24),
          Text(
            'Toutes les demandes',
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          if (admin.loading && admin.tickets.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (admin.error != null && admin.tickets.isEmpty)
            ErrorState(message: ErrorMessages.from(admin.error!), onRetry: () => admin.load())
          else if (admin.tickets.isEmpty)
            const Card(
              child: EmptyState(
                icon: Icons.folder_open_rounded,
                title: 'Aucune demande',
                message: 'Aucune demande de vérification manuelle n’a encore été soumise.',
              ),
            )
          else
            for (final ticket in admin.tickets)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _AdminTicketCard(
                  ticket: ticket,
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => AdminTicketScreen(ticketId: ticket.id),
                      ),
                    );
                    if (context.mounted) await context.read<AdminController>().load();
                  },
                ),
              ),
        ],
      ),
        ),
    );
  }
}

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.stats});

  final AdminStats stats;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Color tone(Color light, Color dark) => isDark ? dark : light;

    final tiles = [
      ('Demandes totales', stats.total, Icons.inbox_rounded,
          tone(const Color(0xFF37474F), const Color(0xFFB9A9D8))),
      ('En attente', stats.pending, Icons.hourglass_empty_rounded,
          tone(const Color(0xFFB26A00), const Color(0xFFFFC24B))),
      ('En vérification', stats.inReview, Icons.visibility_rounded,
          tone(const Color(0xFF1D6FB8), const Color(0xFF5CC8FF))),
      ('Répondues', stats.replied, Icons.mark_email_read_rounded,
          tone(const Color(0xFF2E7D32), const Color(0xFF52E39B))),
      ('Fermées', stats.closed, Icons.archive_rounded,
          tone(const Color(0xFF6B6B6B), const Color(0xFF9E9E9E))),
      ('Non attribuées', stats.unmatched, Icons.help_outline_rounded,
          tone(const Color(0xFFB3261E), const Color(0xFFFF5C8A))),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth > 620 ? 3 : 2;
        final spacing = 12.0;
        final width = (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final tile in tiles)
              SizedBox(
                width: width,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(tile.$3, size: 20, color: tile.$4),
                        const SizedBox(height: 10),
                        Text(
                          '${tile.$2}',
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: tile.$4,
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(tile.$1, style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _AdminTicketCard extends StatelessWidget {
  const _AdminTicketCard({required this.ticket, required this.onTap});

  final KycRequest ticket;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      ticket.ticketCode,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                  StatusPill(status: ticket.status, compact: true),
                ],
              ),
              const SizedBox(height: 12),
              InfoRow(
                label: 'Utilisateur',
                value: ticket.userDisplayName ?? ticket.userEmail ?? 'Inconnu',
              ),
              InfoRow(label: 'Lien du profil Tango', value: ticket.tangoProfileLink),
              InfoRow(label: ticket.registerType.label, value: ticket.registerValue),
              InfoRow(label: 'Créé le', value: formatDate(ticket.createdAt)),
              if (ticket.paymentRequired)
                InfoRow(
                  label: 'État',
                  value: ticket.isSubmitted ? 'Demande soumise' : 'Paiement en attente',
                ),
              InfoRow(
                label: 'Dernière réponse',
                value: ticket.lastReplyAt == null ? 'Aucun' : formatDateTime(ticket.lastReplyAt!),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnmatchedCard extends StatelessWidget {
  const _UnmatchedCard({required this.item, required this.tickets});

  final UnmatchedReply item;
  final List<KycRequest> tickets;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warning = const Color(0xFFB3261E);

    return Card(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: warning.withValues(alpha: 0.35)),
          color: warning.withValues(alpha: 0.05),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline_rounded, size: 20, color: warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.subject?.trim().isNotEmpty == true ? item.subject! : 'Réponse sans objet',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            InfoRow(label: 'From', value: item.fromEmail ?? 'Expéditeur inconnu'),
            InfoRow(label: 'Reason', value: item.reason),
            InfoRow(label: 'Received', value: formatDateTime(item.createdAt)),
            if (item.bodyExcerpt?.trim().isNotEmpty == true) ...[
              const SizedBox(height: 8),
              Text('Excerpt', style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(item.bodyExcerpt!, style: theme.textTheme.bodySmall),
              ),
            ],
            const SizedBox(height: 12),
            if (tickets.isEmpty)
              Text(
                'Aucun ticket disponible pour rattacher cette réponse.',
                style: theme.textTheme.bodySmall,
              )
            else
              TextButton.icon(
                onPressed: () => _attach(context),
                icon: const Icon(Icons.link_rounded, size: 18),
                label: const Text('Rattacher à un ticket'),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _attach(BuildContext context) async {
    final selected = await showModalBottomSheet<KycRequest>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(
                'Rattacher cette réponse à un ticket',
                style: Theme.of(sheetContext).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            for (final ticket in tickets)
              ListTile(
                title: Text(ticket.ticketCode),
                subtitle: Text('${ticket.registerValue} · ${ticket.status.label}'),
                onTap: () => Navigator.of(sheetContext).pop(ticket),
              ),
          ],
        ),
      ),
    );

    if (selected == null || !context.mounted) return;

    final ok = await context.read<AdminController>().resolveUnmatched(item.id, selected.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Réponse rattachée à ${selected.ticketCode}.'
              : ErrorMessages.from(context.read<AdminController>().lastErrorCode ?? ''),
        ),
      ),
    );
  }
}

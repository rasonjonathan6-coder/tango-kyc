/// Full history of the signed-in user's manual KYC verification requests.
///
/// La maquette (écran 9, « Mes tickets ») montre une liste de cartes compactes :
/// code du ticket, intitulé, date, et un statut à droite. Chaque carte ouvre le
/// détail.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/validators.dart';
import '../../models/models.dart';
import '../../state/kyc_controller.dart';
import '../../state/notifications_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/aurora.dart';
import '../widgets/common.dart';
import '../widgets/modern.dart';
import '../widgets/tango_scaffold.dart';
import 'request_details_screen.dart';

class MyRequestsScreen extends StatefulWidget {
  const MyRequestsScreen({super.key, this.embedded = false});

  /// True when hosted inside the shell's [IndexedStack], which supplies the app
  /// bar. Pushed as its own route it shows its own bar, so it keeps a back
  /// button and a title.
  final bool embedded;

  @override
  State<MyRequestsScreen> createState() => _MyRequestsScreenState();
}

class _MyRequestsScreenState extends State<MyRequestsScreen> {
  /// Which chip is active. Presentation only — every request is still loaded,
  /// this just narrows what is shown.
  TicketCategory _filter = TicketCategory.all;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final kyc = context.read<KycController>();
      final notifications = context.read<NotificationsController>();
      kyc.load().then((_) {
        if (!mounted) return;
        notifications.load();
      });
    });
  }

  Future<void> _reload() async {
    final kyc = context.read<KycController>();
    await kyc.load();
    if (!mounted) return;
    await context.read<NotificationsController>().load();
  }

  @override
  Widget build(BuildContext context) {
    final kyc = context.watch<KycController>();
    // The synthetic welcome ticket is not a real request: it is hidden here.
    final all = kyc.requests
        .where((r) => r.registerValue != 'WELCOME')
        .toList();
    final visible = _filter == TicketCategory.all
        ? all
        : all.where((r) => r.status.category == _filter).toList();

    return TangoKycScaffold(
      appBar: widget.embedded ? null : AppBar(title: const Text('Mes tickets')),
      body: RefreshIndicator(onRefresh: _reload, child: _body(kyc, visible)),
    );
  }

  Widget _body(KycController kyc, List<KycRequest> visible) {
    Widget chips() => Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: _CategoryChips(
        selected: _filter,
        onSelected: (value) => setState(() => _filter = value),
      ),
    );

    if (kyc.loading && kyc.requests.isEmpty) {
      return const SkeletonList();
    }

    if (kyc.error != null && kyc.requests.isEmpty) {
      return ListView(
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.2),
          ErrorState(
            message: ErrorMessages.from(kyc.error!),
            onRetry: () => kyc.load(),
          ),
        ],
      );
    }

    if (visible.isEmpty) {
      return ListView(
        padding: AppSpacing.page,
        children: [
          chips(),
          SizedBox(height: MediaQuery.of(context).size.height * 0.08),
          EmptyState(
            icon: Icons.confirmation_number_outlined,
            title: _filter == TicketCategory.all
                ? 'Aucun ticket pour le moment'
                : 'Aucun ticket « ${_filter.label} »',
            message: _filter == TicketCategory.all
                ? 'Vous n’avez pas encore de demande.\nCréez votre premier ticket pour obtenir de l’aide.'
                : 'Aucun ticket ne correspond à ce filtre pour le moment.',
          ),
        ],
      );
    }

    return ListView.builder(
      padding: AppSpacing.page,
      itemCount: visible.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return chips();
        final request = visible[index - 1];
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.md),
          child: _RequestCard(request: request),
        );
      },
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.request});

  final KycRequest request;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return GlassCard(
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => RequestDetailsScreen(ticketId: request.id),
              ),
            );
            if (context.mounted) await context.read<KycController>().load();
          },
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.confirmation_number_rounded,
                      size: 18,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        request.ticketCode,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    StatusPill(status: request.status, compact: true),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  request.registerType.label,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  formatDateTime(request.createdAt),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (request.paymentRequired) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(
                        request.paymentStatus == 'approved'
                            ? Icons.verified_rounded
                            : Icons.schedule_rounded,
                        size: 14,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        request.paymentStatus == 'approved'
                            ? 'Paiement validé'
                            : 'Paiement en attente',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
                if (request.lastReplyAt != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        Icons.mark_email_read_rounded,
                        size: 14,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Réponse le ${formatDateTime(request.lastReplyAt!)}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The horizontal filter chips from the artwork (screen 9).
///
/// The chips are a view over [KycStatus.category]; selecting one only narrows
/// the already-loaded list, it never queries the server again.
class _CategoryChips extends StatelessWidget {
  const _CategoryChips({required this.selected, required this.onSelected});

  final TicketCategory selected;
  final ValueChanged<TicketCategory> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: TicketCategory.values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final category = TicketCategory.values[index];
          final isSelected = category == selected;
          return ChoiceChip(
            label: Text(category.label),
            selected: isSelected,
            onSelected: (_) => onSelected(category),
            showCheckmark: false,
            labelStyle: TextStyle(
              fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
              color: isSelected ? scheme.onPrimary : scheme.onSurfaceVariant,
            ),
            selectedColor: scheme.primary,
            backgroundColor: scheme.surfaceContainerHighest.withValues(
              alpha: 0.5,
            ),
            side: BorderSide(
              color: isSelected ? scheme.primary : scheme.outlineVariant,
            ),
          );
        },
      ),
    );
  }
}

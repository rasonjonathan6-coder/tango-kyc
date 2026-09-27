/// Home: identity, a short welcome and the single active request.
///
/// The home screen is intentionally not a dashboard. Its job is to let the user
/// create a new request (when one is possible) and follow the active one; the
/// full list lives under Historique.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/kyc_journey.dart';
import '../../models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/kyc_controller.dart';
import '../../state/notifications_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/aurora.dart';
import '../widgets/common.dart';
import '../widgets/modern.dart';
import 'mvola_payment_screen.dart';
import 'my_requests_screen.dart';
import 'new_request_screen.dart';
import 'notifications_screen.dart';
import 'request_details_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    final kyc = context.read<KycController>();
    await kyc.load();
    if (!mounted) return;
    await context.read<NotificationsController>().load();
  }

  /// The request currently being tracked: the newest one that is not closed.
  /// The synthetic welcome ticket is never shown (it is closed and not a real
  /// request). A new request may be opened when none is active.
  KycRequest? get _active {
    final requests = context.read<KycController>().requests;
    for (final request in requests) {
      if (request.registerValue == 'WELCOME') continue;
      if (request.status != KycStatus.closed) return request;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final kyc = context.watch<KycController>();
    final unread = context.watch<NotificationsController>().unreadCount;
    final theme = Theme.of(context);
    final active = _active;

    return AuroraBackground(
      child: RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: AppSpacing.page,
        children: [
          AnimatedEntry(
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Icon(Icons.verified_user_rounded,
                      color: theme.colorScheme.primary, size: 26),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Tango KYC',
                          style: theme.textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800)),
                      Text('Vérification de compte',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const NotificationsScreen()),
                  ),
                  tooltip: 'Notifications',
                  icon: unread > 0
                      ? Badge.count(
                          count: unread, child: const Icon(Icons.notifications_none_rounded))
                      : const Icon(Icons.notifications_none_rounded),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          AnimatedEntry(
            delay: const Duration(milliseconds: 40),
            child: Text(
              'Bonjour, ${auth.profile?.greetingName ?? 'there'}',
              style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 6),
          AnimatedEntry(
            delay: const Duration(milliseconds: 60),
            child: Text(
              'Envoyez une demande de vérification et suivez son évolution ici.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          if (kyc.loading && kyc.requests.isEmpty)
            const SkeletonCard(lines: 3)
          else if (active != null)
            AnimatedEntry(
              delay: const Duration(milliseconds: 90),
              child: _ActiveRequestCard(
                request: active,
                onOpen: () => _openTicket(active),
                onPay: active.paymentRequired && !active.isSubmitted
                    ? () => _openPayment(active)
                    : null,
              ),
            )
          else
            AnimatedEntry(
              delay: const Duration(milliseconds: 90),
              child: _NoActiveRequestCard(
                onNew: () => _openNewRequest(),
              ),
            ),
          if (kyc.requests.where((r) => r.registerValue != 'WELCOME').length > 1) ...[
            const SizedBox(height: AppSpacing.lg),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const MyRequestsScreen()),
                ),
                icon: const Icon(Icons.history_rounded, size: 18),
                label: const Text('Voir tout l’historique'),
              ),
            ),
          ],
        ],
      ),
      ),
    );
  }

  Future<void> _openNewRequest() async {
    final created = await Navigator.of(context).push<KycRequest>(
      MaterialPageRoute(builder: (_) => const NewRequestScreen()),
    );
    if (!mounted) return;
    await context.read<KycController>().load();
    if (!mounted) return;
    await context.read<NotificationsController>().load();
    if (created == null || !mounted) return;

    // A request is only officially submitted once its MVola payment has been
    // validated, so the wording - and the next screen - depend on what the
    // server reported, never on the fact that the form was filled in.
    if (created.paymentRequired && !created.isSubmitted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Votre demande est prête. Effectuez le paiement pour finaliser l\'envoi.'),
        ),
      );
      await _openPayment(created);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Votre demande a été envoyée.')),
      );
    }
  }

  Future<void> _openTicket(KycRequest request) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => RequestDetailsScreen(ticketId: request.id)),
    );
    if (!mounted) return;
    await context.read<KycController>().load();
  }

  Future<void> _openPayment(KycRequest request) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MvolaPaymentScreen(ticketId: request.id, ticketCode: request.ticketCode),
      ),
    );
  }
}

class _ActiveRequestCard extends StatelessWidget {
  const _ActiveRequestCard({required this.request, required this.onOpen, this.onPay});

  final KycRequest request;
  final VoidCallback onOpen;
  final VoidCallback? onPay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StatusHero(
          title: 'Votre demande en cours',
          statusLabel: request.status.label,
          statusColor: AppTheme.statusColor(context, request.status.wireValue),
          subtitle: nextActionHint(
            request.status,
            paymentRequired: request.paymentRequired,
            isSubmitted: request.isSubmitted,
          ),
          step: currentStep(
            request.status,
            paymentRequired: request.paymentRequired,
            isSubmitted: request.isSubmitted,
          ).position,
          trailing: Text(
            request.ticketCode,
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppTheme.onHeroMuted,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        OutlinedButton.icon(
          onPressed: onOpen,
          icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
          label: const Text('Voir la demande'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
        ),
        if (onPay != null) ...[
          const SizedBox(height: AppSpacing.sm),
          FilledButton.icon(
            onPressed: onPay,
            icon: const Icon(Icons.account_balance_wallet_rounded, size: 18),
            label: const Text('Payer avec MVola'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
          ),
        ],
      ],
    );
  }
}

class _NoActiveRequestCard extends StatelessWidget {
  const _NoActiveRequestCard({required this.onNew});

  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.assignment_turned_in_rounded,
                    size: 22, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Text('Aucune demande en cours',
                    style:
                        theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Vous pouvez envoyer une nouvelle demande de vérification. '
              'Nous la traiterons manuellement.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onNew,
              icon: const Icon(Icons.add_rounded, size: 20),
              label: const Text('Nouvelle demande'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            ),
          ],
        ),
      ),
    );
  }
}

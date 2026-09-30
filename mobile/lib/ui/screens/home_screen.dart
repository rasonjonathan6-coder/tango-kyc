/// Home: identity, a short welcome and the single active request.
///
/// The home screen is intentionally not a dashboard. Its job is to let the user
/// request a re-verification (when one is possible) and follow the active one;
/// the full list lives under Historique.
///
/// The layout follows one rule of priority: the brand header, then the single
/// dominant "Demander une re-vérification" card, then the state of the request
/// already being tracked, then the lighter secondary entries.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/kyc_journey.dart';
import '../../models/models.dart';
import '../../services/notification_service.dart';
import '../../state/auth_controller.dart';
import '../../state/kyc_controller.dart';
import '../../state/notifications_controller.dart';
import '../../state/settings_controller.dart';
import '../app_shell.dart';
import '../theme/app_theme.dart';
import '../widgets/aurora.dart';
import '../widgets/common.dart';
import '../widgets/home_empty_state.dart';
import '../widgets/home_header.dart';
import '../widgets/home_primary_action.dart';
import '../widgets/modern.dart';
import '../widgets/tango_scaffold.dart';
import 'help_support_screen.dart';
import 'mvola_payment_screen.dart';
import 'my_requests_screen.dart';
import 'new_request_screen.dart';
import 'notification_permission_screen.dart';
import 'profile_screen.dart';
import 'request_details_screen.dart';
import 'request_sent_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refresh();
      _maybeAskForNotifications();
    });
  }

  /// Shows the in-app notification-permission screen exactly once.
  ///
  /// It is skipped when the user already answered, when Firebase is unavailable,
  /// or when the OS permission is already granted — so the app never nags and
  /// never shows a page whose only button would do nothing.
  Future<void> _maybeAskForNotifications() async {
    // Optional so the screen can be hosted without the full app environment.
    final SettingsController settings;
    try {
      settings = context.read<SettingsController>();
    } on ProviderNotFoundException {
      return;
    }
    if (settings.notificationPromptAnswered) return;
    final push = _push();
    if (push == null) return;
    final shouldShow = await NotificationPermissionScreen.shouldShow(push);
    if (!mounted) return;
    if (!shouldShow) {
      await settings.markNotificationPromptAnswered();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NotificationPermissionScreen(
          onDone: (_) {
            settings.markNotificationPromptAnswered();
            if (mounted) Navigator.of(context).maybePop();
          },
        ),
      ),
    );
  }

  PushService? _push() {
    try {
      return Provider.of<PushService>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
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

  /// Opens the profile tab through the shell when hosted in it, so the avatar
  /// behaves exactly like tapping the "Profil" destination. When the screen is
  /// hosted standalone (tests, deep links) there is no shell to switch, so the
  /// profile is pushed as a route instead.
  void _openProfile() {
    final shell = AppShellScope.maybeOf(context);
    if (shell != null) {
      shell.goToProfile();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ProfileScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final kyc = context.watch<KycController>();
    final theme = Theme.of(context);
    final active = _active;

    // The unread notifications are scoped to this account by RLS. They drive the
    // "new reply" banner: if any unread row points at the active ticket, the
    // administration answered and the user has not looked yet.
    final unread = context.watch<NotificationsController>().items.where(
      (n) => n.unread,
    );
    final activeUnread = active == null
        ? 0
        : unread.where((n) => n.ticketId == active.id).length;
    final hasReply = activeUnread > 0;
    final otherCount = kyc.requests
        .where((r) => r.registerValue != 'WELCOME')
        .length;

    return TangoKycScaffold(
      safeArea: false,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _refresh,
          // Decisions follow the space actually available, not a device class:
          // the gutter tightens on a narrow canvas and the column stops growing
          // once the window is wide enough to keep a readable line length.
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppSpacing.maxContentWidth,
                  ),
                  child: ListView(
                    padding: AppSpacing.pageFor(width),
                    children: [
                      AnimatedEntry(
                        child: HomeHeader(
                          greetingName: auth.profile?.greetingName ?? '',
                          onOpenProfile: _openProfile,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      if (hasReply) ...[
                        AnimatedEntry(
                          delay: const Duration(milliseconds: 30),
                          child: _NewReplyBanner(
                            count: activeUnread,
                            onOpen: () => _openTicket(active!),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.md),
                      ],
                      AnimatedEntry(
                        delay: const Duration(milliseconds: 40),
                        child: Text(
                          'Bonjour, ${auth.profile?.greetingName ?? ''}',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.3,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      AnimatedEntry(
                        delay: const Duration(milliseconds: 60),
                        child: Text(
                          'Comment pouvons-nous vous aider ?',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      // 1. The single dominant action, answering "what can I do
                      //    here?" before anything else.
                      AnimatedEntry(
                        delay: const Duration(milliseconds: 90),
                        child: PrimaryActionCard(
                          title: 'Demander une re-vérification',
                          description:
                              'Soumettez votre demande de vérification de compte. '
                              'Notre équipe l’examinera après validation.',
                          ctaLabel: 'Demander une re-vérification',
                          onTap: _openNewRequest,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      // 2. The state of the request already being tracked.
                      AnimatedEntry(
                        delay: const Duration(milliseconds: 130),
                        child: const SectionHeader(
                          title: 'Votre demande en cours',
                          icon: Icons.timelapse_rounded,
                        ),
                      ),
                      if (kyc.loading && kyc.requests.isEmpty)
                        const SkeletonCard(lines: 3)
                      else if (active != null)
                        AnimatedEntry(
                          delay: const Duration(milliseconds: 150),
                          child: _ActiveRequestCard(
                            request: active,
                            hasReply: hasReply,
                            onOpen: () => _openTicket(active),
                          ),
                        )
                      else
                        AnimatedEntry(
                          delay: const Duration(milliseconds: 150),
                          child: NoActiveRequestCard(onStart: _openNewRequest),
                        ),
                      // 3. Secondary entries: deliberately lighter than the
                      //    primary action above.
                      const SizedBox(height: AppSpacing.lg),
                      AnimatedEntry(
                        delay: const Duration(milliseconds: 180),
                        child: _QuickTiles(
                          ticketsCount: otherCount,
                          onTickets: _openHistory,
                          onFaq: _openFaq,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                    ],
                  ),
                ),
              );
            },
          ),
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

    // "Envoyer ma demande" goes straight to the MVola payment: the request is
    // not officially submitted until that payment is really validated, so the
    // outcome screen is presented after the payment screen returns and its
    // wording is taken from the server, never from the fact that the form was
    // filled in.
    await _presentPaymentOutcome(created);
  }

  /// Presents the MVola payment for [request], then shows the matching outcome.
  ///
  /// The outcome is re-read from the server after the payment screen closes, so
  /// a user who abandons the payment can resume it later and a user who paid is
  /// only told the request was sent once the payment is really confirmed. The
  /// resume loop re-uses the same [MvolaPaymentScreen] and never creates a
  /// second ticket: [MvolaController.start] is idempotent, so a resumed attempt
  /// returns the existing live payment row.
  Future<void> _presentPaymentOutcome(KycRequest request) async {
    await _openPayment(request);
    if (!mounted) return;

    await context.read<KycController>().load();
    if (!mounted) return;

    KycRequest current = request;
    try {
      current = await context.read<KycController>().requestById(request.id);
    } catch (_) {
      // Keep the last known state; the list refresh above already succeeded.
    }
    if (!mounted) return;

    final awaitingPayment = current.paymentRequired && !current.isSubmitted;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (routeContext) => RequestSentScreen(
          ticketCode: current.ticketCode,
          awaitingPayment: awaitingPayment,
          onPrimary: () async {
            Navigator.of(routeContext).pop();
            if (awaitingPayment) {
              // Resume: re-open the payment, then re-evaluate the real state.
              await _presentPaymentOutcome(current);
            } else {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => RequestDetailsScreen(ticketId: current.id),
                ),
              );
            }
          },
          onSecondary: () {
            Navigator.of(routeContext).pop();
            if (awaitingPayment) {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => RequestDetailsScreen(ticketId: current.id),
                ),
              );
            }
          },
        ),
      ),
    );
  }

  Future<void> _openHistory() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const MyRequestsScreen()));
  }

  Future<void> _openFaq() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const HelpSupportScreen()));
  }

  Future<void> _openTicket(KycRequest request) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RequestDetailsScreen(ticketId: request.id),
      ),
    );
    if (!mounted) return;
    await context.read<KycController>().load();
  }

  Future<void> _openPayment(KycRequest request) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MvolaPaymentScreen(
          ticketId: request.id,
          ticketCode: request.ticketCode,
        ),
      ),
    );
  }
}

class _ActiveRequestCard extends StatelessWidget {
  const _ActiveRequestCard({
    required this.request,
    required this.onOpen,
    this.hasReply = false,
  });

  final KycRequest request;
  final VoidCallback onOpen;

  /// True when an unread administration reply is waiting on this ticket, which
  /// adds a visible badge and the matching call to action.
  final bool hasReply;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasReply) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.statusColor(
                context,
                'replied',
              ).withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.mark_chat_unread_rounded,
                  size: 18,
                  color: AppTheme.statusColor(context, 'replied'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Nouvelle réponse de l’administration',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: AppTheme.statusColor(context, 'replied'),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        StatusHero(
          title: request.registerType.label,
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
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(46),
          ),
        ),
      ],
    );
  }
}

/// The two secondary entries shown side by side under the primary action.
///
/// Deliberately lighter than the primary card: a compact row of two tappable
/// tiles. Both open a real destination this app already had (the history list
/// and the help/support screen).
///
/// Laid out with a plain [Row] + [Expanded]. The previous [IntrinsicHeight] is
/// gone: it existed only to make `stretch` resolve against a finite height, but
/// both tiles share one structure and therefore one height, so the extra
/// measure pass bought nothing.
class _QuickTiles extends StatelessWidget {
  const _QuickTiles({
    required this.ticketsCount,
    required this.onTickets,
    required this.onFaq,
  });

  final int ticketsCount;
  final VoidCallback onTickets;
  final VoidCallback onFaq;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _QuickTile(
            icon: Icons.confirmation_number_outlined,
            title: 'Mes demandes',
            subtitle: '$ticketsCount enregistré${ticketsCount > 1 ? 's' : ''}',
            onTap: onTickets,
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: _QuickTile(
            icon: Icons.help_outline_rounded,
            title: 'Aide',
            subtitle: 'Questions fréquentes',
            onTap: onFaq,
          ),
        ),
      ],
    );
  }
}

class _QuickTile extends StatelessWidget {
  const _QuickTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

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
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 40,
                  width: 40,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Icon(icon, size: 20, color: scheme.primary),
                ),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A banner shown above everything else when the administration has replied to
/// the ticket the user is tracking and they have not read it yet.
///
/// It is driven by the same server-side `notifications` rows as the bell badge,
/// so it cannot disagree with the badge, and it clears the moment the ticket is
/// opened (which marks those rows read server side).
class _NewReplyBanner extends StatelessWidget {
  const _NewReplyBanner({required this.count, required this.onOpen});

  final int count;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = AppTheme.statusColor(context, 'replied');

    return GlassCard(
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                Container(
                  height: 44,
                  width: 44,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.mark_chat_unread_rounded,
                    color: accent,
                    size: 22,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        count > 1
                            ? '$count nouvelles réponses'
                            : 'Nouvelle réponse à votre demande',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Touchez pour lire le message de l’administration.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

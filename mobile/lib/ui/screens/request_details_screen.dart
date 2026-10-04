/// Ticket detail: request metadata, status history, the administration's
/// messages and — once the payment is confirmed — the owner's reply composer.
///
/// The composer is offered only when the server would accept a reply:
///   * the synthetic welcome ticket never shows one;
///   * a closed ticket never shows one;
///   * a request that owes a payment (`paymentRequired`) whose payment has not
///     been approved (`isSubmitted` false) stays read-only, with a notice that
///     the reply will be available after confirmation.
///
/// This client-side gate is only a courtesy: the authoritative rule lives in
/// the database. [KycController.reply] goes through the `reply-to-ticket` Edge
/// Function, which calls `user_post_message`; that function re-checks ownership,
/// the closed-ticket rule and the payment gate server side, so bypassing the UI
/// cannot post an unpaid reply.
///
/// Admin-authored text is rendered through [LinkifiedText], so a URL in a reply
/// is a real, tappable link. The body itself is never interpreted as markup:
/// the backend strips email headers, quoted history and signatures before
/// storing a reply.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/net_log.dart';
import '../../core/validators.dart';
import '../../models/models.dart';
import '../../state/kyc_controller.dart';
import '../../state/notifications_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/aurora.dart';
import '../widgets/common.dart';
import '../widgets/linkified_text.dart';
import '../widgets/modern.dart';
import 'mvola_payment_screen.dart';

class RequestDetailsScreen extends StatefulWidget {
  const RequestDetailsScreen({super.key, required this.ticketId});

  final String ticketId;

  @override
  State<RequestDetailsScreen> createState() => _RequestDetailsScreenState();
}

class _RequestDetailsScreenState extends State<RequestDetailsScreen> {
  final _scrollController = ScrollController();
  final _replyController = TextEditingController();

  KycRequest? _request;
  List<TicketMessage> _messages = const [];
  List<StatusHistoryEntry> _history = const [];
  bool _loading = true;
  bool _sending = false;
  String? _error;

  /// The synthetic welcome ticket is a read-only system message: it never needs
  /// a payment.
  bool _isWelcome(KycRequest request) => request.registerValue == 'WELCOME';

  /// True when the owner may reply: an open ticket whose payment, when one is
  /// required, has been approved. This mirrors the server gate in
  /// `user_post_message`; the server stays authoritative.
  bool _canReply(KycRequest request) =>
      !_isWelcome(request) &&
      request.status != KycStatus.closed &&
      (!request.paymentRequired || request.isSubmitted);

  /// The read-only notice shown when no composer is available. It names the
  /// exact reason so the user knows what unlocks the reply.
  String _readOnlyNotice(KycRequest request) {
    if (request.status == KycStatus.closed) {
      return 'Cette demande est fermée. Son historique reste consultable.';
    }
    if (request.paymentRequired && !request.isSubmitted) {
      return 'La réponse sera disponible après confirmation de votre paiement.';
    }
    return 'Cette demande est en lecture seule. Pour échanger avec '
        'l’équipe, passez par Aide & support.';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _replyController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final controller = context.read<KycController>();
      final request = await controller.requestById(widget.ticketId);
      final messages = await controller.messages(widget.ticketId);
      final history = await controller.statusHistory(widget.ticketId);
      // Ownership is now proven: requestById only returns a row RLS let us see,
      // so reaching here means the ticket is ours. Clear its notifications now,
      // which also drops the badge if this screen was opened from a push.
      if (mounted) {
        unawaited(context.read<NotificationsController>().markTicketRead(widget.ticketId));
      }
      if (!mounted) return;
      setState(() {
        _request = request;
        _messages = messages;
        _history = history;
        _loading = false;
      });
    } catch (error) {
      netError('requestById', error);
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _sendReply() async {
    final request = _request;
    final body = _replyController.text.trim();
    if (request == null || _sending || body.isEmpty) return;

    setState(() => _sending = true);
    final controller = context.read<KycController>();
    final message = await controller.reply(ticketId: request.id, body: body);
    if (!mounted) return;

    if (message != null) {
      _replyController.clear();
      setState(() {
        _messages = [..._messages, message];
        _sending = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Votre réponse a été envoyée au support.')),
      );
      return;
    }

    // The server refused it. Refresh so the screen reflects the authoritative
    // state (a payment approved or a ticket closed elsewhere), then explain the
    // refusal without ever naming an internal recipient.
    final code = controller.replyErrorCode ?? 'INTERNAL';
    setState(() => _sending = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ErrorMessages.from(code))),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Détail de la demande'),
        actions: [
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Rafraîchir',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorState(message: ErrorMessages.from(_error!), onRetry: _load)
              : _body(),
    );
  }

  /// The scrollable ticket with its pinned footer: the reply composer when the
  /// server would accept a reply, otherwise the read-only explanation. The
  /// welcome ticket has no footer at all.
  Widget _body() {
    final request = _request!;
    final footer = _isWelcome(request)
        ? null
        : (_canReply(request)
            ? _ReplyComposer(
                controller: _replyController,
                sending: _sending,
                onSend: _sendReply,
              )
            : _ReadOnlyNotice(
                icon: Icons.lock_outline_rounded,
                message: _readOnlyNotice(request),
              ));

    return Column(
      children: [
        Expanded(child: _content()),
        if (footer != null)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
              child: footer,
            ),
          ),
      ],
    );
  }

  Widget _content() {
    final request = _request!;
    final theme = Theme.of(context);
    // The synthetic welcome ticket shows only its read-only system message.
    final isWelcome = _isWelcome(request);

    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
      children: [
        SummaryCard(
          title: isWelcome ? 'Bienvenue' : 'Informations de la demande',
          trailing: isWelcome ? null : StatusPill(status: request.status, compact: true),
          children: isWelcome
              ? const [
                  InfoRow(label: 'Type', value: 'Bienvenue'),
                ]
              : [
                  InfoRow(label: 'Ticket ID', value: request.ticketCode),
                  InfoRow(
                    label: 'Profile Link',
                    value: request.tangoProfileLink,
                    valueWidget: LinkifiedText(
                      request.tangoProfileLink,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  InfoRow(label: request.registerType.label, value: request.registerValue),
                  InfoRow(label: 'Statut', value: request.status.label),
                  InfoRow(label: 'Créée le', value: formatDate(request.createdAt)),
                  InfoRow(
                    label: 'Dernière mise à jour',
                    value: formatDateTime(
                        request.lastReplyAt ?? request.updatedAt ?? request.createdAt),
                  ),
                ],
        ),
        if (!isWelcome && request.paymentRequired && !request.isSubmitted) ...[
          const SizedBox(height: AppSpacing.md),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => MvolaPaymentScreen(
                  ticketId: request.id,
                  ticketCode: request.ticketCode,
                ),
              ),
            ),
            icon: const Icon(Icons.account_balance_wallet_rounded, size: 18),
            label: const Text('Payer avec MVola'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
          ),
        ],
        if (!isWelcome) ...[
          const SizedBox(height: AppSpacing.md),
          const _SupportDelayNotice(),
        ],
        if (_history.isNotEmpty) ...[
          const SizedBox(height: 22),
          const SectionHeader(title: 'Historique du statut', icon: Icons.timeline_rounded),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: JourneyTimeline(
                steps: [
                  for (final entry in _history)
                    JourneyStep(
                      label: entry.toStatus.label,
                      detail: '${_actorLabel(entry.actorRole)} · '
                          '${formatDateTime(entry.createdAt)}',
                      done: true,
                    ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 22),
        SectionHeader(
          title: isWelcome ? 'Message' : 'Messages de l’administration',
          icon: Icons.forum_outlined,
        ),
        const SizedBox(height: 12),
        if (_messages.isEmpty)
          const Card(
            child: EmptyState(
              icon: Icons.forum_outlined,
              title: 'Aucun message',
              message: 'Les messages de l’administration apparaîtront ici.',
            ),
          )
        else
          for (final message in _messages)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _MessageBubble(message: message),
            ),
      ],
    );
  }

  String _actorLabel(String role) => switch (role) {
        'admin' => 'Administration',
        'user' => 'Vous',
        _ => 'Système',
      };
}

/// The owner's reply composer, shown only once the payment (when one is
/// required) has been approved. The send action is delegated to the screen; the
/// field is disabled while a send is in flight.
class _ReplyComposer extends StatelessWidget {
  const _ReplyComposer({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LabeledField(
          label: 'Votre réponse',
          controller: controller,
          hint: 'Écrire une réponse...',
          icon: Icons.forum_outlined,
          keyboardType: TextInputType.multiline,
          maxLines: 4,
          enabled: !sending,
        ),
        const SizedBox(height: 14),
        GradientButton(
          onPressed: sending ? null : onSend,
          busy: sending,
          height: 52,
          radius: AppRadius.md,
          icon: Icons.send_rounded,
          child: const Text('Envoyer'),
        ),
      ],
    );
  }
}

/// Sets expectations on the support turnaround: replies usually land within a
/// business day, but the queue can push that out, so a silent ticket is not a
/// lost one. Shown on every real request, whatever its status.
class _SupportDelayNotice extends StatelessWidget {
  const _SupportDelayNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.schedule_rounded,
              size: 20,
              color: theme.colorScheme.secondary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Délai de réponse du support',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Les réponses du support peuvent aller jusqu’à 24 h ouvrées. '
                    'Le support répond généralement sous 24 h ; les délais '
                    'peuvent varier selon le volume de demandes.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A plain read-only explanation shown at the bottom of the ticket, stating
/// where the support channel is or why the reply is not yet available.
class _ReadOnlyNotice extends StatelessWidget {
  const _ReadOnlyNotice({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final TicketMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAdmin = message.senderType == SenderType.admin;
    final isSystem = message.senderType == SenderType.system;

    if (isSystem) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: LinkifiedText(message.body, style: theme.textTheme.bodyMedium),
              ),
            ],
          ),
        ),
      );
    }

    final bubbleColor = isAdmin
        ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.7)
        : theme.colorScheme.primaryContainer;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 4, bottom: 4),
          child: Text(
            '${isAdmin ? 'Administration' : 'Vous'} · ${formatDateTime(message.createdAt)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 11.5,
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(16),
                ),
              ),
              child: LinkifiedText(
                message.body,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: isAdmin
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

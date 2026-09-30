/// Ticket detail: request metadata, status history and the user's conversation
/// with the administration.
///
/// The user owns a ticket and may reply on it through the composer. The rule is
/// enforced server-side by `public.user_post_message`: a ticket that is closed,
/// or one whose MVola payment is still required and not yet confirmed
/// (`paymentRequired && !isSubmitted`), cannot be answered. The screen mirrors
/// that state — the composer is replaced by an explanation — and a
/// `PAYMENT_NOT_CONFIRMED` answer reloads the ticket so a payment confirmed
/// elsewhere flips it back to writable.
///
/// Messages are rendered as plain text; the backend strips email headers,
/// quoted history and signatures before storing a reply, and the body is never
/// interpreted as markup.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/validators.dart';
import '../../models/models.dart';
import '../../state/kyc_controller.dart';
import '../../state/notifications_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
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

  KycRequest? _request;
  List<TicketMessage> _messages = const [];
  List<StatusHistoryEntry> _history = const [];
  bool _loading = true;
  String? _error;
  
  // Reply composer state
  final TextEditingController _replyController = TextEditingController();
  final FocusNode _replyFocus = FocusNode();
  bool _sending = false;

  /// The synthetic welcome ticket is a read-only system message: it never gets
  /// a composer and never needs a payment.
  bool _isWelcome(KycRequest request) => request.registerValue == 'WELCOME';

  /// Whether the request still owes an unconfirmed MVola payment. While this
  /// holds the composer is replaced by an explanation, mirroring the server's
  /// `PAYMENT_NOT_CONFIRMED` guard in `user_post_message`.
  bool get _paymentBlocked {
    final request = _request;
    return request != null &&
        !_isWelcome(request) &&
        request.paymentRequired &&
        !request.isSubmitted;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _replyController.dispose();
    _replyFocus.dispose();
    super.dispose();
  }

  /// Sends the reply currently in the composer.
  ///
  /// Guarded against a double tap: [_sending] short-circuits a second call while
  /// the first is in flight, and the field is cleared only on success so a
  /// network failure never loses what the user typed. A `TICKET_CLOSED` answer
  /// flips the screen to read-only instead of leaving the composer enabled; a
  /// `PAYMENT_NOT_CONFIRMED` answer reloads the ticket so a payment confirmed in
  /// the meantime makes the composer available again.
  Future<void> _send() async {
    if (_sending) return;
    final body = _replyController.text.trim();
    if (body.isEmpty) return;

    setState(() => _sending = true);
    final message = await context.read<KycController>().reply(
      ticketId: widget.ticketId,
      body: body,
    );
    if (!mounted) return;
    setState(() => _sending = false);

    if (message == null) {
      final code = context.read<KycController>().replyErrorCode ?? 'INTERNAL';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(ErrorMessages.from(code))));
      if (code == 'TICKET_CLOSED' || code == 'PAYMENT_NOT_CONFIRMED') await _load();
      return;
    }

    _replyController.clear();
    setState(() => _messages = [..._messages, message]);
    // Bring the new message into view.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    ));
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
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Détail de la demande'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded), tooltip: 'Refresh'),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorState(message: ErrorMessages.from(_error!), onRetry: _load)
              : _body(),
    );
  }

  /// The scrollable ticket with its pinned footer (composer or explanation).
  Widget _body() {
    final request = _request!;
    final footer = _footer(request);
    if (footer == null) return _content();
    return Column(
      children: [
        Expanded(child: _content()),
        footer,
      ],
    );
  }

  Widget _content() {
    final request = _request!;
    final theme = Theme.of(context);
    // The synthetic welcome ticket shows only its read-only system message.
    final isWelcome = request.registerValue == 'WELCOME';

    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
      children: [
        SummaryCard(
          title: isWelcome ? 'Bienvenue' : 'Informations de la demande',
          trailing: isWelcome ? null : StatusPill(status: request.status, compact: true),
          children: isWelcome
              ? const [
                  InfoRow(
                    label: 'Type',
                    value: 'Bienvenue',
                  ),
                ]
              : [
                  InfoRow(label: 'Ticket ID', value: request.ticketCode),
                  InfoRow(
                    label: 'Profile Link',
                    value: request.tangoProfileLink,
                    valueWidget: SelectableText(
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

  /// The composer, pinned below the scrollable ticket so it is always reachable.
  ///
  /// The welcome ticket is a read-only system message and gets no footer. For a
  /// real ticket the footer is the composer when the server would accept a
  /// reply, or an explanation when it would not — the request still owes an
  /// unconfirmed payment, or the ticket is closed.
  Widget? _footer(KycRequest request) {
    if (_isWelcome(request)) return null;

    final Widget body;
    if (_paymentBlocked) {
      body = _PaymentBlockedNotice(
        onPay: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => MvolaPaymentScreen(
              ticketId: request.id,
              ticketCode: request.ticketCode,
            ),
          ),
        ),
      );
    } else if (request.status == KycStatus.closed) {
      body = const _ReadOnlyNotice(
        icon: Icons.lock_outline_rounded,
        message: 'Cette demande est fermée : vous ne pouvez plus y répondre.',
      );
    } else {
      body = _composer();
    }

    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
          ),
        ),
        child: body,
      ),
    );
  }

  /// The reply composer, shown only when the server would accept a reply: the
  /// ticket is open and any required payment is confirmed.
  Widget _composer() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextField(
            controller: _replyController,
            focusNode: _replyFocus,
            minLines: 1,
            maxLines: 4,
            enabled: !_sending,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _send(),
            decoration: const InputDecoration(
              hintText: 'Écrire un message…',
              contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
          ),
        ),
        const SizedBox(width: 10),
        IconButton.filled(
          onPressed: _sending ? null : _send,
          icon: _sending
              ? const SizedBox(
                  height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2.2))
              : const Icon(Icons.send_rounded),
          tooltip: 'Envoyer',
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

/// Shown in place of the composer while the request still owes an unconfirmed
/// MVola payment. It states the rule plainly and offers the payment action, so
/// the user understands the reply is blocked until the payment is confirmed.
class _PaymentBlockedNotice extends StatelessWidget {
  const _PaymentBlockedNotice({required this.onPay});

  final VoidCallback onPay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_clock_rounded, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Réponse bloquée',
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Votre paiement MVola doit être confirmé avant de pouvoir répondre à cette demande.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: onPay,
              icon: const Icon(Icons.account_balance_wallet_rounded, size: 18),
              label: const Text('Payer avec MVola'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A plain read-only explanation shown in place of the composer when the ticket
/// cannot be answered for a non-payment reason (e.g. it is closed).
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
                child: Text(
                  message.body,
                  style: theme.textTheme.bodyMedium,
                ),
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
              child: Text(
                message.body,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: isAdmin ? theme.colorScheme.onSurface : theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

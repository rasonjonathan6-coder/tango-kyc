/// Ticket detail: request metadata, status history and the messages sent by the
/// administration.
///
/// There is deliberately **no reply box**: the flow is ADMIN -> USER only. The
/// user can read messages but cannot post one, and the backend rejects any
/// attempt regardless of the UI. Messages are rendered as plain text; the
/// backend strips email headers, quoted history and signatures before storing a
/// reply, and the body is never interpreted as markup.
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Sends the reply currently in the composer.
  ///
  /// Guarded against a double tap: [_sending] short-circuits a second call while
  /// the first is in flight, and the field is cleared only on success so a
  /// network failure never loses what the user typed. A `TICKET_CLOSED` answer
  /// flips the screen to read-only instead of leaving the composer enabled.
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
      if (code == 'TICKET_CLOSED') await _load();
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
              : _content(),
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

  String _actorLabel(String role) => switch (role) {
        'admin' => 'Administration',
        'user' => 'Vous',
        _ => 'Système',
      };
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

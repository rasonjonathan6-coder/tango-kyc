/// Admin view of a single ticket: user information, request history and the
/// ability to reply, change status, and see the conversation.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/validators.dart';
import '../../models/models.dart';
import '../../state/admin_controller.dart';
import '../widgets/common.dart';

class AdminTicketScreen extends StatefulWidget {
  const AdminTicketScreen({super.key, required this.ticketId});

  final String ticketId;

  @override
  State<AdminTicketScreen> createState() => _AdminTicketScreenState();
}

class _AdminTicketScreenState extends State<AdminTicketScreen> {
  final _replyController = TextEditingController();

  KycRequest? _ticket;
  List<TicketMessage> _messages = const [];
  bool _loading = true;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _replyController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final admin = context.read<AdminController>();
      final messages = await admin.messages(widget.ticketId);
      final ticket = admin.tickets.firstWhere(
        (t) => t.id == widget.ticketId,
        orElse: () => throw const FormatException('Ticket not in the current listing.'),
      );
      if (!mounted) return;
      setState(() {
        _ticket = ticket;
        _messages = messages;
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

  Future<void> _send() async {
    final body = _replyController.text.trim();
    if (body.isEmpty) return;

    setState(() => _sending = true);
    final admin = context.read<AdminController>();
    final ok = await admin.postMessage(widget.ticketId, body);

    if (!mounted) return;
    setState(() => _sending = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorMessages.from(admin.lastErrorCode ?? ''))),
      );
      return;
    }
    _replyController.clear();
    await _load();
  }

  Future<void> _changeStatus(KycStatus status) async {
    final admin = context.read<AdminController>();
    final ok = await admin.setStatus(widget.ticketId, status);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorMessages.from(admin.lastErrorCode ?? ''))),
      );
      return;
    }
    await _load();
  }

  Future<void> _requestPayment() async {
    final admin = context.read<AdminController>();
    final ok = await admin.requestPayment(widget.ticketId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? 'Paiement demandé. L’utilisateur a été notifié.'
            : ErrorMessages.from(admin.lastErrorCode ?? '')),
      ),
    );
    if (ok) await _load();
  }

  /// Human label for the server-derived payment status, so an admin can see at
  /// a glance whether a request is still awaiting payment or officially
  /// submitted.
  static String _paymentStatusLabel(String? status) => switch (status) {
        'approved' => 'Validé',
        'pending' => 'Vérification en cours',
        'rejected' => 'Refusé',
        'awaiting_submission' => 'Non soumis',
        'not_required' => 'Non requis',
        _ => 'Inconnu',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Ticket'),
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
    final ticket = _ticket!;
    final theme = Theme.of(context);

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
            children: [
              SummaryCard(
                title: 'User information',
                trailing: StatusPill(status: ticket.status, compact: true),
                children: [
                  InfoRow(label: 'User', value: ticket.userDisplayName ?? ticket.userEmail ?? 'Unknown'),
                  InfoRow(label: 'Email', value: ticket.userEmail ?? 'Not available'),
                  InfoRow(label: 'Ticket ID', value: ticket.ticketCode),
                  InfoRow(label: 'Profile Link', value: ticket.tangoProfileLink),
                  InfoRow(label: ticket.registerType.label, value: ticket.registerValue),
                  InfoRow(label: 'Created', value: formatDate(ticket.createdAt)),
                  InfoRow(
                    label: 'Last Reply',
                    value: ticket.lastReplyAt == null ? 'None' : formatDateTime(ticket.lastReplyAt!),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SummaryCard(
                title: 'Paiement',
                trailing: StatusPill(
                  status: ticket.isSubmitted ? KycStatus.inReview : KycStatus.pending,
                  compact: true,
                ),
                children: [
                  InfoRow(
                    label: 'État de la demande',
                    value: ticket.isSubmitted ? 'Demande soumise' : 'Paiement en attente',
                  ),
                  InfoRow(
                    label: 'Paiement requis',
                    value: ticket.paymentRequired ? 'Oui' : 'Non',
                  ),
                  InfoRow(
                    label: 'Statut du paiement',
                    value: _paymentStatusLabel(ticket.paymentStatus),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: ticket.paymentRequired ? null : _requestPayment,
                    icon: const Icon(Icons.account_balance_wallet_outlined, size: 18),
                    label: const Text('Demander un paiement'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SummaryCard(
                title: 'Change status',
                children: [
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final status in KycStatus.values)
                        ChoiceChip(
                          label: Text(status.label),
                          selected: ticket.status == status,
                          onSelected: (_) => _changeStatus(status),
                        ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Text(
                'Conversation',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              if (_messages.isEmpty)
                const Card(
                  child: EmptyState(
                    icon: Icons.forum_outlined,
                    title: 'No messages',
                    message: 'This ticket has no conversation yet.',
                  ),
                )
              else
                for (final message in _messages)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Chip(
                                  label: Text(message.senderType.label),
                                  visualDensity: VisualDensity.compact,
                                ),
                                const Spacer(),
                                Text(
                                  formatDateTime(message.createdAt),
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            SelectableText(message.body, style: theme.textTheme.bodyMedium),
                          ],
                        ),
                      ),
                    ),
                  ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
              ),
              color: theme.colorScheme.surface,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _replyController,
                    minLines: 1,
                    maxLines: 4,
                    enabled: !_sending,
                    decoration: const InputDecoration(
                      hintText: 'Reply to the user...',
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
                  tooltip: 'Send reply',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Ticket detail: full request metadata and the conversation with support.
///
/// Messages are rendered as plain text. The backend strips email headers,
/// quoted history and technical signatures before storing a reply, and the body
/// is never interpreted as markup, so no email raw content is shown here.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/validators.dart';
import '../../models/models.dart';
import '../../state/kyc_controller.dart';
import '../widgets/common.dart';
import 'mvola_payment_screen.dart';

class RequestDetailsScreen extends StatefulWidget {
  const RequestDetailsScreen({super.key, required this.ticketId});

  final String ticketId;

  @override
  State<RequestDetailsScreen> createState() => _RequestDetailsScreenState();
}

class _RequestDetailsScreenState extends State<RequestDetailsScreen> {
  final _replyController = TextEditingController();
  final _scrollController = ScrollController();

  KycRequest? _request;
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
      if (!mounted) return;
      setState(() {
        _request = request;
        _messages = messages;
        _loading = false;
      });
      _scrollToBottom();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final body = _replyController.text.trim();
    if (body.isEmpty) return;

    setState(() => _sending = true);
    try {
      await context.read<KycController>().sendReply(widget.ticketId, body);
      _replyController.clear();
      await _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorMessages.from(error))),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Request details'),
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

    return Column(
      children: [
        Expanded(
          child: ListView(
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
            children: [
              SummaryCard(
                title: 'Request information',
                trailing: StatusPill(status: request.status, compact: true),
                children: [
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
                  InfoRow(label: 'Status', value: request.status.label),
                  InfoRow(label: 'Created', value: formatDate(request.createdAt)),
                  InfoRow(
                    label: 'Last update',
                    value: formatDateTime(request.lastReplyAt ?? request.updatedAt ?? request.createdAt),
                  ),
                  const SizedBox(height: 12),
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
                    label: const Text('Pay with MVola'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
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
                    title: 'No messages yet',
                    message: 'Support replies will appear here once they are received.',
                  ),
                )
              else
                for (final message in _messages)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _MessageBubble(message: message),
                  ),
            ],
          ),
        ),
        _replyBar(theme),
      ],
    );
  }

  Widget _replyBar(ThemeData theme) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6))),
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
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  hintText: 'Write a message to support...',
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
              tooltip: 'Send',
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
    final isFromUser = message.senderType == SenderType.user;
    final isSystem = message.senderType == SenderType.system;

    if (isSystem) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            message.body,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    final alignment = isFromUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bubbleColor = isFromUser
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.7);
    final textColor = isFromUser
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;

    final maxWidth = MediaQuery.of(context).size.width * 0.82;

    return Column(
      crossAxisAlignment: alignment,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 4, bottom: 4),
          child: Text(
            '${isFromUser ? 'You' : 'Support'} · ${formatDateTime(message.createdAt)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 11.5,
            ),
          ),
        ),
        Align(
          alignment: isFromUser ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isFromUser ? 16 : 4),
                  bottomRight: Radius.circular(isFromUser ? 4 : 16),
                ),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
              // Plain text only: email bodies are cleaned server side and are
              // never rendered as markup.
              child: SelectableText(
                message.body,
                style: theme.textTheme.bodyMedium?.copyWith(color: textColor, height: 1.45),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Admin queue for manual MVola payments.
///
/// Shows the payments a user has confirmed and that still need a decision, then
/// the full history. Approving or refusing is the only action; the amount and
/// the recipient are decided by the backend and are shown read-only here.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/validators.dart';
import '../../models/models.dart';
import '../../state/admin_mvola_controller.dart';
import '../../state/auth_controller.dart';
import '../widgets/common.dart';

class AdminMvolaScreen extends StatefulWidget {
  const AdminMvolaScreen({super.key});

  @override
  State<AdminMvolaScreen> createState() => _AdminMvolaScreenState();
}

class _AdminMvolaScreenState extends State<AdminMvolaScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AdminMvolaController>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AdminMvolaController>();
    final isAdmin = context.watch<AuthController>().isAdmin;
    final theme = Theme.of(context);

    if (!isAdmin) {
      return const EmptyState(
        icon: Icons.lock_outline_rounded,
        title: 'Admin access required',
        message: 'Your account does not have permission to view this queue.',
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('MVola payments'),
        actions: [
          IconButton(
            onPressed: controller.loading ? null : () => controller.load(),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: controller.loading && controller.payments.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : controller.error != null && controller.payments.isEmpty
              ? ErrorState(
                  message: ErrorMessages.from(controller.lastErrorCode ?? 'INTERNAL'),
                  onRetry: () => controller.load(),
                )
              : RefreshIndicator(
                  onRefresh: () => controller.load(),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(18, 12, 18, 32),
                    children: [
                      Text('Awaiting verification',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(
                        'A user confirmed a transfer and entered a reference. '
                        'Check the reference against the MVola statement before deciding.',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 12),
                      if (controller.awaitingReview.isEmpty)
                        const Card(
                          child: EmptyState(
                            icon: Icons.inbox_rounded,
                            title: 'Nothing to verify',
                            message: 'No payment is waiting for a decision.',
                          ),
                        )
                      else
                        for (final payment in controller.awaitingReview)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _PaymentCard(
                              payment: payment,
                              onApprove: () => _approve(payment),
                              onReject: () => _reject(payment),
                            ),
                          ),
                      const SizedBox(height: 24),
                      Text('All payments',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 12),
                      if (controller.payments.isEmpty)
                        const Card(
                          child: EmptyState(
                            icon: Icons.receipt_long_outlined,
                            title: 'No payments',
                            message: 'No MVola payment has been started yet.',
                          ),
                        )
                      else
                        for (final payment in controller.payments)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _PaymentCard(payment: payment, compact: true),
                          ),
                    ],
                  ),
                ),
    );
  }

  Future<void> _approve(MvolaPayment payment) async {
    final confirmed = await _confirm(
      title: 'Approve this payment?',
      message: 'Approve ${payment.amountLabel} for ${payment.ticketCode ?? 'this request'}. '
          'Only do this once you have matched the reference against the MVola statement.',
      confirmLabel: 'Approve',
    );
    if (!confirmed || !mounted) return;

    final controller = context.read<AdminMvolaController>();
    final ok = await controller.decide(
      paymentId: payment.id,
      decision: MvolaStatus.approved,
    );
    if (!mounted) return;
    _report(ok, controller.lastErrorCode, 'Payment approved.');
  }

  Future<void> _reject(MvolaPayment payment) async {
    final reason = await _askReason();
    if (reason == null || !mounted) return;

    final controller = context.read<AdminMvolaController>();
    final ok = await controller.decide(
      paymentId: payment.id,
      decision: MvolaStatus.rejected,
      reason: reason,
    );
    if (!mounted) return;
    _report(ok, controller.lastErrorCode, 'Payment refused.');
  }

  void _report(bool ok, String? code, String successMessage) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? successMessage : ErrorMessages.from(code ?? 'INTERNAL')),
      ),
    );
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<String?> _askReason() async {
    final controller = TextEditingController();
    String? error;

    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: const Text('Refuse this payment'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Explain what is wrong so the user can correct it. '
                'This message is shown to them.',
              ),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: true,
                maxLines: 3,
                maxLength: 500,
                decoration: InputDecoration(
                  hintText: 'e.g. Reference MVola introuvable.',
                  errorText: error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.length < 3) {
                  setState(() => error = 'Please write at least a few words.');
                  return;
                }
                Navigator.of(dialogContext).pop(value);
              },
              child: const Text('Refuse'),
            ),
          ],
        ),
      ),
    );

    controller.dispose();
    return result;
  }
}

class _PaymentCard extends StatelessWidget {
  const _PaymentCard({required this.payment, this.onApprove, this.onReject, this.compact = false});

  final MvolaPayment payment;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final actionable = onApprove != null && onReject != null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    payment.ticketCode ?? 'Request',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                _MvolaStatusPill(status: payment.status),
              ],
            ),
            const SizedBox(height: 4),
            if (payment.userEmail != null)
              Text(
                payment.userEmail!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            const SizedBox(height: 10),
            InfoRow(label: 'Amount', value: payment.amountLabel),
            InfoRow(
              label: 'Reference',
              value: payment.transactionReference ?? 'Not provided',
              valueWidget: payment.transactionReference == null
                  ? Text('Not provided',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant))
                  : SelectableText(
                      payment.transactionReference!,
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
            ),
            if (payment.payerNumber != null)
              InfoRow(label: 'Paid from', value: payment.payerNumber!),
            InfoRow(label: 'Started', value: formatDateTime(payment.createdAt)),
            if (payment.submittedAt != null)
              InfoRow(label: 'Submitted', value: formatDateTime(payment.submittedAt!)),
            if (payment.rejectionReason != null)
              InfoRow(label: 'Refusal reason', value: payment.rejectionReason!),
            if (payment.reviewedAt != null)
              InfoRow(label: 'Reviewed', value: formatDateTime(payment.reviewedAt!)),
            if (actionable && !compact) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onReject,
                      icon: const Icon(Icons.close_rounded, size: 18),
                      label: const Text('Refuse'),
                      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 46)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onApprove,
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('Approve'),
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MvolaStatusPill extends StatelessWidget {
  const _MvolaStatusPill({required this.status});

  final MvolaStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (status) {
      MvolaStatus.pending => const Color(0xFFB26A00),
      MvolaStatus.approved => const Color(0xFF2E7D32),
      MvolaStatus.rejected => scheme.error,
      MvolaStatus.cancelled => scheme.onSurfaceVariant,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        status.label,
        style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 11.5),
      ),
    );
  }
}

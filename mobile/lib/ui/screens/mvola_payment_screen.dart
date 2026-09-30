/// Manual MVola payment for one ticket.
///
/// The screen walks the user through a transfer they make themselves: it shows
/// the recipient, the amount and a dialable USSD code, then collects the
/// transaction reference. It never claims the payment succeeded - an admin
/// verifies the transfer, and the status shown here reflects only what the
/// server reports.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/validators.dart';
import '../../models/models.dart';
import '../../state/mvola_controller.dart';
import '../widgets/common.dart';
import '../widgets/tango_scaffold.dart';

class MvolaPaymentScreen extends StatefulWidget {
  const MvolaPaymentScreen({
    super.key,
    required this.ticketId,
    this.ticketCode,
  });

  final String ticketId;
  final String? ticketCode;

  @override
  State<MvolaPaymentScreen> createState() => _MvolaPaymentScreenState();
}

class _MvolaPaymentScreenState extends State<MvolaPaymentScreen> {
  final _referenceController = TextEditingController();
  final _payerController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  String? _referenceError;
  String? _payerError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = context.read<MvolaController>();
      controller.reset();
      controller.load(widget.ticketId);
    });
  }

  @override
  void dispose() {
    _referenceController.dispose();
    _payerController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final controller = context.read<MvolaController>();
    final payment = await controller.start(widget.ticketId);
    if (!mounted) return;
    if (payment == null) {
      _showError(controller.lastErrorCode);
    }
  }

  Future<void> _submit() async {
    final referenceError = Validators.validateMvolaReference(_referenceController.text);
    final payerError = Validators.validateMvolaPayerNumber(_payerController.text);
    setState(() {
      _referenceError = referenceError;
      _payerError = payerError;
    });
    if (referenceError != null || payerError != null) return;

    final controller = context.read<MvolaController>();
    final payment = controller.payment;
    if (payment == null) return;

    final ok = await controller.submit(
      paymentId: payment.id,
      transactionReference: Validators.normalize(_referenceController.text),
      payerNumber: _payerController.text.trim().isEmpty
          ? null
          : Validators.normalize(_payerController.text),
    );
    if (!mounted) return;
    if (ok) {
      _referenceController.clear();
      _payerController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Détails envoyés. Le support vérifiera votre transfert.')),
      );
    } else {
      _showError(controller.lastErrorCode);
    }
  }

  void _showError(String? code) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ErrorMessages.from(code ?? 'INTERNAL'))),
    );
  }

  /// Opens the dialer with the USSD code. A USSD code cannot be dialled from a
  /// plain `tel:` URI on every Android build, so this reports honestly when the
  /// device refuses instead of pretending the dialer opened.
  Future<void> _dial(String ussdCode) async {
    final uri = Uri(scheme: 'tel', path: Uri.encodeComponent(ussdCode));
    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched && mounted) _dialFailed();
    } catch (_) {
      if (mounted) _dialFailed();
    }
  }

  void _dialFailed() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Impossible d’ouvrir le composeur. Saisissez le code USSD manuellement.'),
      ),
    );
  }

  Future<void> _copy(String value, String label) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label copied.')));
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<MvolaController>();

    return TangoKycScaffold(
      appBar: AppBar(
        title: const Text('Paiement Mobile Money'),
        actions: [
          IconButton(
            onPressed: controller.loading ? null : () => controller.load(widget.ticketId),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: controller.loading
          ? const Center(child: CircularProgressIndicator())
          : controller.error != null && controller.config == null
              ? ErrorState(
                  message: ErrorMessages.from(controller.lastErrorCode ?? 'INTERNAL'),
                  onRetry: () => controller.load(widget.ticketId),
                )
              : _content(controller),
    );
  }

  Widget _content(MvolaController controller) {
    final payment = controller.payment;
    final config = controller.config;

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 28),
      children: [
        AnimatedEntry(
          child: _Header(ticketCode: widget.ticketCode),
        ),
        const SizedBox(height: 18),

        // Already decided or awaiting review: show the outcome, not the form.
        if (payment != null && payment.status != MvolaStatus.pending)
          AnimatedEntry(child: _DecidedCard(payment: payment)),
        if (payment != null && payment.status == MvolaStatus.pending)
          AnimatedEntry(child: _PendingCard(payment: payment, onSubmit: _submit, formKey: _formKey,
              referenceController: _referenceController, payerController: _payerController,
              referenceError: _referenceError, payerError: _payerError,
              submitting: controller.submitting, busy: controller.busy)),
        if (payment == null && config != null)
          AnimatedEntry(
            child: _InstructionsCard(
              config: config,
              starting: controller.starting,
              onStart: _start,
              onDial: () => _dial(config.ussdCode),
              onCopy: (value, label) => _copy(value, label),
            ),
          ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({this.ticketCode});

  final String? ticketCode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(Icons.account_balance_wallet_rounded,
                  color: theme.colorScheme.primary, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Paiement MVola',
                      style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                  if (ticketCode != null)
                    Text(ticketCode!,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'Envoyez le montant depuis votre portefeuille MVola, puis saisissez la '
          'référence de la transaction ci-dessous. Le support vérifie chaque transfert.',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// The payment details to act on, before anything is submitted.
class _InstructionsCard extends StatelessWidget {
  const _InstructionsCard({
    required this.config,
    required this.starting,
    required this.onStart,
    required this.onDial,
    required this.onCopy,
  });

  final MvolaConfig config;
  final bool starting;
  final VoidCallback onStart;
  final VoidCallback onDial;
  final void Function(String value, String label) onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Détails du paiement',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            InfoRow(
              label: 'Amount',
              value: config.amountLabel,
              valueWidget: Text(
                config.amountLabel,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
            InfoRow(
              label: 'MVola number',
              value: config.recipientNumber,
              valueWidget: Row(
                children: [
                  Expanded(
                    child: SelectableText(config.recipientNumber,
                        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  IconButton(
                    onPressed: () => onCopy(config.recipientNumber, 'Number'),
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    tooltip: 'Copy number',
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
            InfoRow(
              label: 'USSD code',
              value: config.ussdCode,
              valueWidget: Row(
                children: [
                  Expanded(
                    child: SelectableText(config.ussdCode,
                        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  IconButton(
                    onPressed: () => onCopy(config.ussdCode, 'USSD code'),
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    tooltip: 'Copy code',
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
            if (config.instructions.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(config.instructions, style: theme.textTheme.bodySmall),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onDial,
                    icon: const Icon(Icons.dialpad_rounded, size: 19),
                    label: const Text('Composer'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: starting ? null : onStart,
                    icon: starting
                        ? const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.arrow_forward_rounded, size: 19),
                    label: Text(starting ? 'Veuillez patienter…' : 'J’ai payé'),
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A payment that exists but has not been verified yet.
class _PendingCard extends StatelessWidget {
  const _PendingCard({
    required this.payment,
    required this.onSubmit,
    required this.formKey,
    required this.referenceController,
    required this.payerController,
    required this.referenceError,
    required this.payerError,
    required this.submitting,
    required this.busy,
  });

  final MvolaPayment payment;
  final Future<void> Function() onSubmit;
  final GlobalKey<FormState> formKey;
  final TextEditingController referenceController;
  final TextEditingController payerController;
  final String? referenceError;
  final String? payerError;
  final bool submitting;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final awaitingReview = payment.isAwaitingReview;

    return Column(
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('Paiement',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                    ),
                    _MvolaPill(status: payment.status),
                  ],
                ),
                const SizedBox(height: 6),
                InfoRow(label: 'Amount', value: payment.amountLabel),
                InfoRow(label: 'MVola number', value: payment.recipientNumber),
                InfoRow(label: 'USSD code', value: payment.ussdCode),
                if (payment.transactionReference != null)
                  InfoRow(label: 'Reference', value: payment.transactionReference!),
                if (payment.submittedAt != null)
                  InfoRow(label: 'Submitted', value: formatDateTime(payment.submittedAt!)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        if (awaitingReview)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Icon(Icons.hourglass_top_rounded, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Votre paiement est en cours de vérification. Le support examinera la '
                      'référence de la transaction et mettra à jour cette demande.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Form(
                key: formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Confirmez votre transfert',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(
                      'Saisissez la référence fournie par MVola après le transfert.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 16),
                    LabeledField(
                      label: 'MVola transaction reference',
                      controller: referenceController,
                      hint: 'e.g. MV-123456789',
                      errorText: referenceError,
                      enabled: !busy,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 14),
                    LabeledField(
                      label: 'Numéro payeur (facultatif)',
                      controller: payerController,
                      hint: '+261 34 12 345 67',
                      errorText: payerError,
                      enabled: !busy,
                      keyboardType: TextInputType.phone,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => onSubmit(),
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: busy ? null : onSubmit,
                      icon: submitting
                          ? const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.check_rounded, size: 19),
                      label: Text(submitting ? 'Sending...' : 'Envoyer les détails du paiement'),
                      style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 50)),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A payment an admin has approved or refused.
class _DecidedCard extends StatelessWidget {
  const _DecidedCard({required this.payment});

  final MvolaPayment payment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final approved = payment.status == MvolaStatus.approved;
    final color = approved ? const Color(0xFF2E7D32) : theme.colorScheme.error;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  approved ? Icons.verified_rounded : Icons.cancel_rounded,
                  color: color,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    approved ? 'Paiement approuvé' : 'Paiement refusé',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700, color: color),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              approved
                  ? 'Votre transfert a été vérifié. Merci.'
                  : 'Le support n’a pas pu vérifier ce transfert.',
              style: theme.textTheme.bodyMedium,
            ),
            if (!approved && payment.rejectionReason != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: color.withValues(alpha: 0.3)),
                ),
                child: Text(payment.rejectionReason!, style: theme.textTheme.bodyMedium),
              ),
              const SizedBox(height: 8),
              Text(
                'Vous pouvez démarrer un nouveau paiement depuis l’écran de la demande.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 10),
            InfoRow(label: 'Amount', value: payment.amountLabel),
            if (payment.transactionReference != null)
              InfoRow(label: 'Reference', value: payment.transactionReference!),
            if (payment.reviewedAt != null)
              InfoRow(label: 'Reviewed', value: formatDateTime(payment.reviewedAt!)),
          ],
        ),
      ),
    );
  }
}

class _MvolaPill extends StatelessWidget {
  const _MvolaPill({required this.status});

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

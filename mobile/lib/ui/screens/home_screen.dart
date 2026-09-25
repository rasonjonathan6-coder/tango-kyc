/// Home: greeting, the manual KYC verification form, the post-submission
/// confirmation and a summary of recent requests.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/validators.dart';
import '../../models/models.dart';
import '../../state/auth_controller.dart';
import '../../state/kyc_controller.dart';
import '../widgets/common.dart';
import 'my_requests_screen.dart';
import 'request_details_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _formKey = GlobalKey<FormState>();
  final _profileLinkController = TextEditingController();
  final _registerController = TextEditingController();

  String? _profileLinkError;
  String? _registerError;
  KycRequest? _justCreated;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<KycController>().load();
    });
  }

  @override
  void dispose() {
    _profileLinkController.dispose();
    _registerController.dispose();
    super.dispose();
  }

  /// Live hint so the user can see how their input will be interpreted.
  String? get _detectedHint {
    final value = Validators.normalize(_registerController.text);
    if (value.isEmpty) return null;
    return Validators.looksLikeEmail(value)
        ? 'Will be registered as an email address.'
        : 'Will be registered as a phone number.';
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();

    final validation = Validators.validateRequestForm(
      profileLink: _profileLinkController.text,
      registerValue: _registerController.text,
    );
    setState(() {
      _profileLinkError = validation.profileLinkError;
      _registerError = validation.registerError;
    });
    if (!validation.isValid) return;

    final controller = context.read<KycController>();
    final ticket = await controller.submit(
      tangoProfileLink: Validators.normalize(_profileLinkController.text),
      registerValue: Validators.normalize(_registerController.text),
    );

    if (!mounted) return;

    if (ticket == null) {
      final code = controller.lastErrorCode ?? 'INTERNAL';
      // Keep field-specific problems next to the offending field.
      setState(() {
        if (code == 'PROFILE_LINK_REQUIRED' ||
            code == 'PROFILE_LINK_INVALID' ||
            code == 'PROFILE_LINK_TOO_LONG') {
          _profileLinkError = ErrorMessages.from(code);
        }
        if (code == 'REGISTER_REQUIRED' ||
            code == 'REGISTER_EMAIL_INVALID' ||
            code == 'REGISTER_PHONE_INVALID') {
          _registerError = ErrorMessages.from(code);
        }
      });

      if (code != 'PROFILE_LINK_REQUIRED' &&
          code != 'PROFILE_LINK_INVALID' &&
          code != 'PROFILE_LINK_TOO_LONG' &&
          code != 'REGISTER_REQUIRED' &&
          code != 'REGISTER_EMAIL_INVALID' &&
          code != 'REGISTER_PHONE_INVALID') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ErrorMessages.from(code)),
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
          ),
        );
      }
      return;
    }

    _profileLinkController.clear();
    _registerController.clear();
    setState(() {
      _justCreated = ticket;
      _profileLinkError = null;
      _registerError = null;
    });
    controller.clearLastCreated();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final kyc = context.watch<KycController>();
    final theme = Theme.of(context);

    return RefreshIndicator(
      onRefresh: () => kyc.load(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 32),
        children: [
          AnimatedEntry(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Bonjour, ${auth.profile?.greetingName ?? 'there'}',
                  style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text(
                  'Submit a request and we will review your verification manually.',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          if (_justCreated != null)
            AnimatedEntry(
              delay: const Duration(milliseconds: 60),
              child: _SuccessCard(
                ticket: _justCreated!,
                onOpen: () => _openTicket(_justCreated!),
                onDismiss: () => setState(() => _justCreated = null),
              ),
            ),
          if (_justCreated != null) const SizedBox(height: 18),
          AnimatedEntry(
            delay: const Duration(milliseconds: 120),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.assignment_turned_in_rounded,
                              size: 22, color: theme.colorScheme.primary),
                          const SizedBox(width: 10),
                          Text(
                            'Manual KYC Verification',
                            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      LabeledField(
                        label: 'Tango Profile Link',
                        controller: _profileLinkController,
                        hint: 'https://...',
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.next,
                        errorText: _profileLinkError,
                        enabled: !kyc.submitting,
                        validator: Validators.validateProfileLink,
                      ),
                      const SizedBox(height: 20),
                      LabeledField(
                        label: 'Register Email or Phone Number',
                        controller: _registerController,
                        hint: 'Email or phone number',
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.done,
                        errorText: _registerError,
                        helper: _detectedHint,
                        enabled: !kyc.submitting,
                        validator: Validators.validateRegisterValue,
                        onSubmitted: (_) => _submit(),
                      ),
                      const SizedBox(height: 26),
                      FilledButton(
                        onPressed: kyc.submitting ? null : _submit,
                        child: kyc.submitting
                            ? const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2.4),
                                  ),
                                  SizedBox(width: 12),
                                  Text('Sending...'),
                                ],
                              )
                            : const Text('Envoyer ma demande'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 26),
          AnimatedEntry(
            delay: const Duration(milliseconds: 160),
            child: Row(
              children: [
                Text(
                  'My Requests',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                if (kyc.requests.isNotEmpty)
                  TextButton(
                    onPressed: () => _openMyRequests(context),
                    child: const Text('See all'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          AnimatedEntry(
            delay: const Duration(milliseconds: 200),
            child: _RecentRequests(
              loading: kyc.loading,
              error: kyc.error,
              requests: kyc.requests.take(3).toList(),
              onRetry: () => kyc.load(),
              onOpen: _openTicket,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openMyRequests(BuildContext context) async {
    final controller = context.read<KycController>();
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const MyRequestsScreen()),
    );
    await controller.load();
  }

  Future<void> _openTicket(KycRequest request) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => RequestDetailsScreen(ticketId: request.id)),
    );
    if (mounted) await context.read<KycController>().load();
  }
}

class _SuccessCard extends StatelessWidget {
  const _SuccessCard({required this.ticket, required this.onOpen, required this.onDismiss});

  final KycRequest ticket;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final success = const Color(0xFF2E7D32);

    return Card(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: success.withValues(alpha: 0.35)),
          color: success.withValues(alpha: 0.06),
        ),
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle_rounded, color: success),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Votre demande a été envoyée.',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close_rounded, size: 20),
                  tooltip: 'Dismiss',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('Ticket ID', style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 2),
            SelectableText(
              ticket.ticketCode,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                fontFeatures: const [],
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text('Status: ', style: theme.textTheme.bodyMedium),
                StatusPill(status: ticket.status, compact: true),
              ],
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: onOpen,
              icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
              label: const Text('View request'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentRequests extends StatelessWidget {
  const _RecentRequests({
    required this.loading,
    required this.error,
    required this.requests,
    required this.onRetry,
    required this.onOpen,
  });

  final bool loading;
  final String? error;
  final List<KycRequest> requests;
  final VoidCallback onRetry;
  final ValueChanged<KycRequest> onOpen;

  @override
  Widget build(BuildContext context) {
    if (loading && requests.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (error != null && requests.isEmpty) {
      return ErrorState(message: ErrorMessages.from(error!), onRetry: onRetry);
    }

    if (requests.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: EmptyState(
            icon: Icons.inbox_rounded,
            title: 'No requests yet',
            message: 'Your manual KYC verification requests will appear here.',
          ),
        ),
      );
    }

    return Column(
      children: [
        for (final request in requests)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _RequestTile(request: request, onTap: () => onOpen(request)),
          ),
      ],
    );
  }
}

class _RequestTile extends StatelessWidget {
  const _RequestTile({required this.request, required this.onTap});

  final KycRequest request;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Manual KYC Verification',
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  StatusPill(status: request.status, compact: true),
                ],
              ),
              const SizedBox(height: 12),
              _Meta(label: 'Ticket', value: request.ticketCode, monospace: true),
              const SizedBox(height: 4),
              _Meta(label: 'Created', value: formatDate(request.createdAt)),
              const SizedBox(height: 4),
              _Meta(label: request.registerType.label, value: request.registerValue),
            ],
          ),
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.label, required this.value, this.monospace = false});

  final String label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 92,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: monospace ? 0.4 : 0,
            ),
          ),
        ),
      ],
    );
  }
}

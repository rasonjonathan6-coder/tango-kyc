/// Full history of the signed-in user's manual KYC verification requests.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/validators.dart';
import '../../models/models.dart';
import '../../state/kyc_controller.dart';
import '../../state/notifications_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/modern.dart';
import 'request_details_screen.dart';

class MyRequestsScreen extends StatefulWidget {
  const MyRequestsScreen({super.key});

  @override
  State<MyRequestsScreen> createState() => _MyRequestsScreenState();
}

class _MyRequestsScreenState extends State<MyRequestsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final kyc = context.read<KycController>();
      final notifications = context.read<NotificationsController>();
      kyc.load().then((_) {
        if (!mounted) return;
        notifications.sync(kyc.requests);
      });
    });
  }

  Future<void> _reload() async {
    final kyc = context.read<KycController>();
    await kyc.load();
    if (!mounted) return;
    context.read<NotificationsController>().sync(kyc.requests);
  }

  @override
  Widget build(BuildContext context) {
    final kyc = context.watch<KycController>();

    return Scaffold(
      appBar: AppBar(title: const Text('My Requests')),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: _body(kyc),
      ),
    );
  }

  Widget _body(KycController kyc) {
    if (kyc.loading && kyc.requests.isEmpty) {
      return const SkeletonList();
    }

    if (kyc.error != null && kyc.requests.isEmpty) {
      return ListView(
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.2),
          ErrorState(message: ErrorMessages.from(kyc.error!), onRetry: () => kyc.load()),
        ],
      );
    }

    if (kyc.requests.isEmpty) {
      return ListView(
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.12),
          const EmptyState(
            icon: Icons.inbox_rounded,
            title: 'No requests yet',
            message: 'Submit a manual KYC verification request from the Home screen.',
          ),
        ],
      );
    }

    return ListView.builder(
      padding: AppSpacing.page,
      itemCount: kyc.requests.length,
      itemBuilder: (context, index) {
        final request = kyc.requests[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.md),
          child: _RequestCard(request: request),
        );
      },
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.request});

  final KycRequest request;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => RequestDetailsScreen(ticketId: request.id)),
          );
          if (context.mounted) await context.read<KycController>().load();
        },
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
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
              const SizedBox(height: 14),
              InfoRow(label: 'Ticket', value: request.ticketCode),
              InfoRow(label: 'Status', value: request.status.label),
              InfoRow(label: 'Created', value: formatDate(request.createdAt)),
              InfoRow(label: request.registerType.label, value: request.registerValue),
              if (request.lastReplyAt != null)
                InfoRow(label: 'Last reply', value: formatDateTime(request.lastReplyAt!)),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Open',
                      style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary),
                    ),
                    Icon(Icons.chevron_right_rounded, color: theme.colorScheme.primary, size: 20),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

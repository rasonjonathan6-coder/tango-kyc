/// Dedicated notifications screen.
///
/// The feed is the caller's own persisted rows (one owner per row, enforced by
/// RLS). Marking read is persisted server side, so it survives a restart; each
/// row navigates to the ticket it refers to.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/validators.dart';
import '../../models/models.dart';
import '../../state/notifications_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/aurora.dart';
import '../widgets/common.dart';
import '../widgets/modern.dart';
import 'request_details_screen.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<NotificationsController>().load();
    });
  }

  Future<void> _open(NotificationItem item) async {
    final controller = context.read<NotificationsController>();
    await controller.markRead(item.id);
    if (item.ticketId == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => RequestDetailsScreen(ticketId: item.ticketId!)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<NotificationsController>();

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          if (controller.hasUnread)
            TextButton(
              onPressed: controller.markAllRead,
              child: const Text('Tout lire'),
            ),
        ],
      ),
      body: AuroraBackground(
        child: RefreshIndicator(
          onRefresh: controller.load,
          child: _body(controller),
        ),
      ),
    );
  }

  Widget _body(NotificationsController controller) {
    if (controller.loading && controller.items.isEmpty) {
      return const SkeletonList();
    }

    if (controller.error != null && controller.items.isEmpty) {
      return ListView(
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.18),
          ErrorState(
            message: ErrorMessages.from(controller.error!),
            onRetry: controller.load,
          ),
        ],
      );
    }

    if (controller.items.isEmpty) {
      return ListView(
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.12),
          const EmptyState(
            icon: Icons.notifications_none_rounded,
            title: 'Aucune notification',
            message: 'Vous serez informé ici de chaque étape de vos demandes.',
          ),
        ],
      );
    }

    return ListView.builder(
      padding: AppSpacing.page,
      itemCount: controller.items.length,
      itemBuilder: (context, index) {
        final item = controller.items[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.md),
          child: _NotificationCard(item: item, onTap: () => _open(item)),
        );
      },
    );
  }
}

class _NotificationCard extends StatelessWidget {
  const _NotificationCard({required this.item, required this.onTap});

  final NotificationItem item;
  final VoidCallback onTap;

  IconData get _icon => switch (item.type) {
        'welcome' => Icons.waving_hand_rounded,
        'request_submitted' => Icons.send_rounded,
        'request_received' => Icons.inbox_rounded,
        'status_changed' => Icons.sync_rounded,
        'payment_requested' => Icons.account_balance_wallet_rounded,
        'payment_confirmed' => Icons.verified_rounded,
        'request_approved' => Icons.check_circle_rounded,
        'request_rejected' => Icons.cancel_rounded,
        'admin_message' => Icons.forum_rounded,
        _ => Icons.notifications_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: item.unread ? 0.14 : 0.06),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(_icon, size: 20, color: scheme.primary),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.title,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: item.unread ? FontWeight.w700 : FontWeight.w600,
                            ),
                          ),
                        ),
                        if (item.unread)
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.body,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      formatDateTime(item.createdAt),
                      style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (item.ticketId != null) ...[
                const SizedBox(width: AppSpacing.xs),
                Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant, size: 20),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

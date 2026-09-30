/// Support chat — interface only.
///
/// IMPORTANT, and deliberate: this app has **no support-chat backend**. Rather
/// than fake a conversation, the composer is disabled and the screen says so.
/// The real support channel in this product is the KYC ticket thread, so the
/// screen offers a button into that flow instead of pretending to send messages.
///
/// When a chat backend is added, [SupportChatScreen] is where it plugs in: give
/// it a message list and an `onSend` callback and remove the "not connected"
/// notice. Nothing else has to change.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/aurora.dart';
import '../widgets/common.dart';
import '../widgets/tango_scaffold.dart';
import 'new_request_screen.dart';

class SupportChatScreen extends StatelessWidget {
  const SupportChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return TangoKycScaffold(
      appBar: AppBar(title: const Text('Support')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
              children: [
                AnimatedEntry(
                  child: Row(
                    children: [
                      Container(
                        height: 44,
                        width: 44,
                        decoration: BoxDecoration(
                          gradient: AppTheme.actionGradient,
                          shape: BoxShape.circle,
                          boxShadow: AppTheme.glow(
                            AppColors.violet,
                            opacity: 0.4,
                            blur: 18,
                          ),
                        ),
                        child: const Icon(
                          Icons.support_agent_rounded,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Équipe Tango KYC',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                Container(
                                  width: 7,
                                  height: 7,
                                  decoration: BoxDecoration(
                                    color: scheme.onSurfaceVariant,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'Réponse sous 24h',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                AnimatedEntry(
                  delay: const Duration(milliseconds: 60),
                  child: GlassCard(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.info_outline_rounded,
                              size: 18,
                              color: scheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Le chat direct n’est pas encore activé',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Pour obtenir de l’aide maintenant, ouvrez une demande : '
                          'le support vous répondra dans le ticket, par email et par '
                          'notification. C’est le canal officiel, et il est suivi.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.55,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
              child: GradientButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const NewRequestScreen(),
                  ),
                ),
                height: 54,
                radius: 30,
                icon: Icons.add_comment_outlined,
                child: const Text('Ouvrir une demande'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Aide & support: FAQ, contact and the legal pages.
///
/// Matches the reference artwork's screen 13: a list of entries under a title,
/// each a glass row. Where the app already had a real destination it is wired
/// through; the FAQ entries expand in place, and the support contact opens the
/// real ticket flow (the app's support channel) rather than pretending to.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/aurora.dart';
import '../widgets/common.dart';
import '../widgets/tango_scaffold.dart';
import 'support_chat_screen.dart';

/// One FAQ question and its answer.
class _Faq {
  const _Faq(this.question, this.answer);

  final String question;
  final String answer;
}

class HelpSupportScreen extends StatelessWidget {
  const HelpSupportScreen({super.key});

  static const _faqs = [
    _Faq(
      'Comment se déroule la vérification ?',
      'Vous envoyez une demande avec les informations de votre compte Tango. '
          'L’équipe support vérifie manuellement, puis vous répond dans le ticket '
          'et par email.',
    ),
    _Faq(
      'Combien de temps prend une réponse ?',
      'Le support répond généralement sous 24 heures ouvrées. Vous recevez une '
          'notification dès qu’une réponse arrive.',
    ),
    _Faq(
      'Pourquoi un paiement MVola est-il demandé ?',
      'Certaines demandes nécessitent des frais de traitement. Tant que le '
          'paiement n’est pas validé, la demande n’est pas officiellement envoyée.',
    ),
    _Faq(
      'Mes documents sont-ils téléversés ici ?',
      'Non. Aucun document d’identité n’est téléversé depuis cette application. '
          'Le support vous envoie un lien sécurisé si une vérification est planifiée.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return TangoKycScaffold(
      appBar: AppBar(title: const Text('Aide & support')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 32),
        children: [
          AnimatedEntry(
            child: Text(
              'Comment pouvons-nous vous aider ?',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 14),
          AnimatedEntry(
            delay: const Duration(milliseconds: 50),
            child: _ActionRow(
              icon: Icons.forum_outlined,
              title: 'Contacter le support',
              subtitle: 'Nous répondons sous 24h',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SupportChatScreen(),
                ),
              ),
            ),
          ),
          const SizedBox(height: 22),
          AnimatedEntry(
            delay: const Duration(milliseconds: 90),
            child: Text(
              'Questions fréquentes',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < _faqs.length; i++)
            AnimatedEntry(
              delay: Duration(milliseconds: 120 + i * 40),
              child: _FaqTile(faq: _faqs[i]),
            ),
          const SizedBox(height: 22),
          AnimatedEntry(
            delay: const Duration(milliseconds: 260),
            child: Text(
              'Informations légales',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 8),
          AnimatedEntry(
            delay: const Duration(milliseconds: 300),
            child: const _ActionRow(
              icon: Icons.description_outlined,
              title: 'Conditions d’utilisation',
              subtitle: 'Nos conditions',
            ),
          ),
          AnimatedEntry(
            delay: const Duration(milliseconds: 330),
            child: const _ActionRow(
              icon: Icons.privacy_tip_outlined,
              title: 'Politique de confidentialité',
              subtitle: 'Vos données sont protégées',
            ),
          ),
        ],
      ),
    );
  }
}

/// A glass row with a gradient icon tile, a title and a subtitle.
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        padding: EdgeInsets.zero,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Container(
                    height: 42,
                    width: 42,
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(icon, size: 21, color: scheme.primary),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An expandable FAQ entry.
class _FaqTile extends StatelessWidget {
  const _FaqTile({required this.faq});

  final _Faq faq;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: EdgeInsets.zero,
        child: Material(
          color: Colors.transparent,
          child: Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 16),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              title: Text(
                faq.question,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    faq.answer,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

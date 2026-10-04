/// The Tango KYC assistant screen (in-app chatbot).
///
/// The assistant answers help questions from a closed, server-side knowledge
/// base; it is not a support agent and cannot see anyone's dossier. The screen
/// is honest about that, keeps a link into the real support channel, and hides
/// the composer when the server reports no provider is configured.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/validators.dart';
import '../../services/assistant_service.dart';
import '../../state/assistant_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/aurora.dart';
import '../widgets/common.dart';
import '../widgets/linkified_text.dart';
import '../widgets/tango_scaffold.dart';
import 'new_request_screen.dart';

class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    final controller = context.read<AssistantController>();
    _scrollToEnd();
    await controller.send(text);
    _scrollToEnd();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AssistantController>();

    return TangoKycScaffold(
      appBar: AppBar(
        title: const Text('Assistant'),
        actions: [
          if (!controller.isEmpty)
            IconButton(
              tooltip: 'Nouvelle conversation',
              onPressed: controller.reset,
              icon: const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _transcript(controller)),
          if (controller.configured)
            _composer(controller)
          else
            _unavailable(),
        ],
      ),
    );
  }

  Widget _transcript(AssistantController controller) {
    if (controller.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
        children: [
          _header(),
          const SizedBox(height: 20),
          const AnimatedEntry(
            child: GlassCard(
              padding: EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _IntroLine('Posez une question sur la vérification KYC, les délais, ou le paiement MVola.'),
                  _IntroLine('L’assistant répond à partir des informations officielles de Tango KYC.'),
                  _IntroLine('Pour un problème de dossier précis, ouvrez une demande : l’équipe vous répondra.'),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
      itemCount: controller.messages.length + (controller.sending ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= controller.messages.length) {
          return const _TypingBubble();
        }
        return _MessageBubble(message: controller.messages[index]);
      },
    );
  }

  Widget _header() {
    final theme = Theme.of(context);
    return AnimatedEntry(
      child: Row(
        children: [
          Container(
            height: 44,
            width: 44,
            decoration: BoxDecoration(
              gradient: AppTheme.actionGradient,
              shape: BoxShape.circle,
              boxShadow: AppTheme.glow(AppColors.violet, opacity: 0.4, blur: 18),
            ),
            child: const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Assistant Tango KYC',
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  'Réponses instantanées, 24h/24',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _composer(AssistantController controller) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (controller.error != null) ...[
              Padding(
                padding: const EdgeInsets.only(left: 6, bottom: 6),
                child: Text(
                  ErrorMessages.from(controller.error!),
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
                ),
              ),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: TextField(
                      controller: _input,
                      enabled: !controller.sending,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Écrivez votre question…',
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _SendButton(enabled: !controller.sending, onPressed: _send),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _unavailable() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 14),
        child: Column(
          children: [
            GlassCard(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded, size: 18, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'L’assistant automatique n’est pas disponible pour le moment. '
                      'Ouvrez une demande : l’équipe Tango KYC vous répondra.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            GradientButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NewRequestScreen()),
              ),
              height: 52,
              radius: 28,
              icon: Icons.add_comment_outlined,
              child: const Text('Ouvrir une demande'),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final AssistantMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fromUser = message.fromUser;

    return Align(
      alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
        decoration: BoxDecoration(
          color: fromUser
              ? scheme.primary.withValues(alpha: 0.14)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.7),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(fromUser ? 18 : 4),
            bottomRight: Radius.circular(fromUser ? 4 : 18),
          ),
          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: LinkifiedText(
          message.text,
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
        ),
      ),
    );
  }
}

class _TypingBubble extends StatelessWidget {
  const _TypingBubble();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
            ),
            const SizedBox(width: 10),
            Text(
              'L’assistant écrit…',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.enabled, required this.onPressed});

  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      height: 48,
      child: Material(
        color: enabled ? AppColors.violet : Theme.of(context).colorScheme.outlineVariant,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onPressed : null,
          child: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

/// A single intro bullet in the empty state.
class _IntroLine extends StatelessWidget {
  const _IntroLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Form to submit a new manual KYC verification request.
///
/// Reached from the home screen. On success it pops with the created ticket so
/// the caller can open the MVola payment; it does not render the ticket itself.
///
/// The request type is fixed to a single category ("Vérification refusée"): the
/// backend only accepts a profile link and a register value, so no type field is
/// transmitted.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/validators.dart';
import '../../state/kyc_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/auth_kit.dart';
import '../widgets/aurora.dart';
import '../widgets/common.dart';
import '../widgets/modern.dart';
import '../widgets/tango_scaffold.dart';

class NewRequestScreen extends StatefulWidget {
  const NewRequestScreen({super.key});

  @override
  State<NewRequestScreen> createState() => _NewRequestScreenState();
}

class _NewRequestScreenState extends State<NewRequestScreen> {
  final _profileLinkController = TextEditingController();
  final _registerController = TextEditingController();

  String? _profileLinkError;
  String? _registerError;

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
        ? 'Sera enregistré comme adresse email.'
        : 'Sera enregistré comme numéro de téléphone.';
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

      final isFieldError =
          code == 'PROFILE_LINK_REQUIRED' ||
          code == 'PROFILE_LINK_INVALID' ||
          code == 'PROFILE_LINK_TOO_LONG' ||
          code == 'REGISTER_REQUIRED' ||
          code == 'REGISTER_EMAIL_INVALID' ||
          code == 'REGISTER_PHONE_INVALID';
      if (!isFieldError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ErrorMessages.from(code)),
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
          ),
        );
      }
      return;
    }

    controller.clearLastCreated();
    // Hand the created request back so the caller opens the MVola payment
    // immediately. The request is not presented as "sent" until that payment is
    // validated by the administration.
    Navigator.of(context).pop(ticket);
  }

  @override
  Widget build(BuildContext context) {
    final submitting = context.watch<KycController>().submitting;
    final theme = Theme.of(context);

    return TangoKycScaffold(
      appBar: AppBar(title: const Text('Demander une re-vérification')),
      body: ListView(
        padding: AppSpacing.page,
        children: [
          // "Type de demande" — the request type is fixed to a single category.
          // The backend stores no type field, so this is presented, not chosen.
          AnimatedEntry(
            child: Text(
              'Type de demande',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 12),
          AnimatedEntry(delay: const Duration(milliseconds: 30), child: const _RequestTypeCard()),
          const SizedBox(height: 28),
          // The two fields the backend actually consumes.
          AnimatedEntry(
            delay: const Duration(milliseconds: 90),
            child: const SectionHeader(
              title: 'Informations de votre compte',
              icon: Icons.badge_outlined,
            ),
          ),
          const SizedBox(height: 6),
          AnimatedEntry(
            delay: const Duration(milliseconds: 95),
            child: Text(
              'Renseignez le lien de votre profil Tango et l’adresse liée à votre '
              'compte. Le support vérifie ensuite manuellement.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 20),
          AnimatedEntry(
            delay: const Duration(milliseconds: 100),
            child: NeonField(
              label: 'Lien du profil Tango',
              controller: _profileLinkController,
              hint: 'https://...',
              icon: Icons.link_rounded,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              enabled: !submitting,
              validator: Validators.validateProfileLink,
              radius: AppRadius.lg,
            ),
          ),
          if (_profileLinkError != null) ...[
            const SizedBox(height: 8),
            _FieldError(message: _profileLinkError!),
          ],
          const SizedBox(height: 20),
          AnimatedEntry(
            delay: const Duration(milliseconds: 120),
            child: NeonField(
              label: 'Email ou numéro enregistré',
              controller: _registerController,
              hint: 'Email ou numéro',
              icon: Icons.alternate_email_rounded,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              enabled: !submitting,
              validator: Validators.validateRegisterValue,
              onSubmitted: (_) => _submit(),
              radius: AppRadius.lg,
            ),
          ),
          if (_registerError != null) ...[
            const SizedBox(height: 8),
            _FieldError(message: _registerError!),
          ],
          if (_detectedHint != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 15,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _detectedHint!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 30),
          AnimatedEntry(
            delay: const Duration(milliseconds: 160),
            child: GradientButton(
              onPressed: submitting ? null : _submit,
              busy: submitting,
              height: 56,
              radius: 30,
              icon: Icons.send_rounded,
              child: const Text('Envoyer ma demande'),
            ),
          ),
        ],
      ),
    );
  }
}

/// The single request category. Fixed, not a choice: the app only handles
/// refused verifications, and the backend stores no type field.
class _RequestTypeCard extends StatelessWidget {
  const _RequestTypeCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: scheme.primary, width: 1.6),
      ),
      child: Row(
        children: [
          Icon(Icons.gpp_bad_outlined, size: 20, color: scheme.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              'Vérification refusée',
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          Icon(Icons.radio_button_checked_rounded, size: 20, color: scheme.primary),
        ],
      ),
    );
  }
}

/// Inline error text matching the neon field's error colour.
class _FieldError extends StatelessWidget {
  const _FieldError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Text(
      message,
      style: TextStyle(
        color: isDark ? const Color(0xFFFF8FA8) : Theme.of(context).colorScheme.error,
        fontSize: 12.5,
      ),
    );
  }
}

/// "Sécurité" — password and sign-in security.
///
/// Reached from the profile list (reference artwork, screen 12). It offers the
/// one security action the app really supports: changing the password while
/// signed in, through [AuthController.updatePassword]. Password reset by email
/// stays where it was (the "Réinitialiser le mot de passe" flow).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/validators.dart';
import '../../state/auth_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/auth_kit.dart';
import '../widgets/aurora.dart';
import '../widgets/common.dart';
import '../widgets/tango_scaffold.dart';

class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final auth = context.read<AuthController>();
    final ok = await auth.updatePassword(_passwordController.text);
    if (!mounted) return;
    if (ok) {
      _passwordController.clear();
      _confirmController.clear();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Mot de passe mis à jour.')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorMessages.from(auth.lastError ?? ''))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final busy = auth.busy;
    final theme = Theme.of(context);

    return TangoKycScaffold(
      appBar: AppBar(title: const Text('Sécurité')),
      body: ListView(
        padding: AppSpacing.page,
        children: [
          AnimatedEntry(
            child: SummaryCard(
              title: 'Connexion',
              children: [
                InfoRow(
                  label: 'Email',
                  value:
                      auth.profile?.email ??
                      auth.session?.user.email ??
                      'Non disponible',
                ),
                const InfoRow(label: 'Méthode', value: 'Email et mot de passe'),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          AnimatedEntry(
            delay: const Duration(milliseconds: 60),
            child: Text(
              'Changer le mot de passe',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                NeonField(
                  label: 'Nouveau mot de passe',
                  controller: _passwordController,
                  hint: '8 caractères minimum',
                  icon: Icons.lock_outline_rounded,
                  obscureText: true,
                  enabled: !busy,
                  validator: Validators.validatePassword,
                  radius: AppRadius.lg,
                ),
                const SizedBox(height: 18),
                NeonField(
                  label: 'Confirmez le nouveau mot de passe',
                  controller: _confirmController,
                  hint: 'Ressaisissez le mot de passe',
                  icon: Icons.lock_reset_rounded,
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  enabled: !busy,
                  validator: (value) => Validators.validatePasswordConfirmation(
                    _passwordController.text,
                    value,
                  ),
                  onSubmitted: (_) => _submit(),
                  radius: AppRadius.lg,
                ),
                const SizedBox(height: 26),
                GradientButton(
                  onPressed: busy ? null : _submit,
                  busy: busy,
                  height: 54,
                  radius: 28,
                  icon: Icons.verified_user_rounded,
                  child: const Text('Mettre à jour le mot de passe'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          AnimatedEntry(
            delay: const Duration(milliseconds: 90),
            child: Text(
              'Si vous avez oublié votre mot de passe, déconnectez-vous puis utilisez '
              '« Mot de passe oublié » sur l’écran de connexion.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

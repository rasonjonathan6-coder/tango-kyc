/// Registration screen. When Supabase requires email confirmation the account is
/// created without a session and the user is told to check their inbox rather
/// than being dropped into a signed-in state that does not exist. Confirmation
/// is completed by the emailed link (PKCE callback), never by a code request
/// from this screen.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/validators.dart';
import '../../state/auth_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/aurora.dart';
import '../widgets/auth_kit.dart';
import '../widgets/tango_scaffold.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _obscure = true;
  bool _awaitingConfirmation = false;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final auth = context.read<AuthController>();
    final email = Validators.normalize(_emailController.text);
    final ok = await auth.signUp(
      email: email,
      password: _passwordController.text,
      displayName: _nameController.text,
    );

    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ErrorMessages.from(auth.lastError ?? '')),
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
        ),
      );
      return;
    }

    // A missing session means Supabase sent a confirmation email instead of
    // immediately signing the user in.
    //
    // The confirmation LINK is the only path offered from here. Requesting an
    // email OTP would call `signInWithOtp`, which mints a new PKCE code
    // verifier and overwrites the one `signUp` just stored — the emailed link
    // would then fail with `bad_code_verifier`. The user is told to open the
    // link on this device instead.
    if (auth.isSignedIn) {
      Navigator.of(context).pop();
    } else {
      setState(() => _awaitingConfirmation = true);
    }
  }

  Future<void> _resend() async {
    final auth = context.read<AuthController>();
    final ok = await auth.resendConfirmation(
      Validators.normalize(_emailController.text),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Email de confirmation envoyé.'
              : ErrorMessages.from(auth.lastError ?? ''),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();

    if (_awaitingConfirmation) {
      return AuthBackground(
        child: TangoKycScaffold(
          body: AuthScreenLayout(
            children: [
              const Reveal(child: Center(child: BrandLockup())),
              const SizedBox(height: 22),
              const Reveal(
                delay: Duration(milliseconds: 60),
                child: LogoMark(
                  size: 74,
                  animate: false,
                  iconSize: 34,
                  icon: Icons.mark_email_unread_rounded,
                ),
              ),
              const SizedBox(height: 20),
              Reveal(
                delay: const Duration(milliseconds: 90),
                child: Text(
                  'Vérifiez votre boîte mail',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Reveal(
                delay: const Duration(milliseconds: 120),
                child: AuthSubtitle(
                  'Ouvrez le lien envoyé à ${Validators.normalize(_emailController.text)} '
                  'sur cet appareil pour activer votre compte, puis connectez-vous.',
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 30),
              Reveal(
                delay: const Duration(milliseconds: 160),
                child: GradientButton(
                  onPressed: () => Navigator.of(context).pop(),
                  height: 60,
                  radius: 32,
                  gradient: AppTheme.actionGradient,
                  icon: Icons.login_rounded,
                  child: const Text('Retour à la connexion'),
                ),
              ),
              const SizedBox(height: 10),
              Reveal(
                delay: const Duration(milliseconds: 200),
                child: Center(
                  child: AuthTextLink(
                    label: 'Renvoyer l’email de confirmation',
                    color: AppColors.magenta,
                    onPressed: auth.busy ? null : _resend,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return AuthBackground(
      child: TangoKycScaffold(
        body: AuthScreenLayout(
          children: [
            const Reveal(child: Center(child: BrandLockup())),
            const SizedBox(height: 14),
            const Reveal(
              delay: Duration(milliseconds: 50),
              child: AuthHeading(
                lines: [
                  [HeadingSegment('Créer votre')],
                  [HeadingSegment('compte', gradient: true)],
                ],
              ),
            ),
            const SizedBox(height: 10),
            Reveal(
              delay: const Duration(milliseconds: 80),
              child: AuthSubtitle(
                'Quelques informations suffisent pour soumettre\net suivre votre demande KYC.',
              ),
            ),
            const SizedBox(height: 22),
            Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Reveal(
                    delay: const Duration(milliseconds: 110),
                    child: NeonField(
                      label: 'Nom complet (optionnel)',
                      controller: _nameController,
                      hint: 'Nom complet',
                      icon: Icons.person_outline_rounded,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.name],
                      enabled: !auth.busy,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Reveal(
                    delay: const Duration(milliseconds: 140),
                    child: NeonField(
                      label: 'Email',
                      controller: _emailController,
                      hint: 'vous@exemple.com',
                      icon: Icons.alternate_email_rounded,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.email],
                      enabled: !auth.busy,
                      validator: Validators.validateEmail,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Reveal(
                    delay: const Duration(milliseconds: 170),
                    child: NeonField(
                      label: 'Mot de passe',
                      controller: _passwordController,
                      hint: 'Votre mot de passe',
                      icon: Icons.lock_rounded,
                      obscureText: _obscure,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.newPassword],
                      enabled: !auth.busy,
                      validator: Validators.validatePassword,
                      suffix: _EyeToggle(
                        obscure: _obscure,
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Reveal(
                    delay: const Duration(milliseconds: 200),
                    child: NeonField(
                      label: 'Confirmez le mot de passe',
                      controller: _confirmController,
                      hint: 'Confirmez votre mot de passe',
                      icon: Icons.lock_outline_rounded,
                      obscureText: _obscure,
                      textInputAction: TextInputAction.done,
                      enabled: !auth.busy,
                      validator: (value) =>
                          Validators.validatePasswordConfirmation(
                            _passwordController.text,
                            value,
                          ),
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                  const SizedBox(height: 22),
                  Reveal(
                    delay: const Duration(milliseconds: 240),
                    child: GradientButton(
                      onPressed: auth.busy ? null : _submit,
                      busy: auth.busy,
                      height: 62,
                      radius: 32,
                      gradient: AppTheme.actionGradient,
                      icon: Icons.person_add_alt_1_rounded,
                      child: const Text('Créer mon compte'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Reveal(
                    delay: const Duration(milliseconds: 280),
                    child: Center(
                      child: AuthTextLink(
                        label: 'Vous avez déjà un compte ? Se connecter',
                        color: AppColors.magenta,
                        chevron: true,
                        onPressed: auth.busy
                            ? null
                            : () => Navigator.of(context).maybePop(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Reveal(
                    delay: Duration(milliseconds: 310),
                    child: AuthFooter(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The eye affordance on the password field, matching the login screen.
class _EyeToggle extends StatelessWidget {
  const _EyeToggle({required this.obscure, required this.onPressed});

  final bool obscure;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: IconButton(
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        tooltip: obscure ? 'Afficher' : 'Masquer',
        icon: Icon(
          obscure ? Icons.visibility_off_rounded : Icons.visibility_rounded,
          size: 22,
          color: context.tokens.textSecondary,
        ),
      ),
    );
  }
}

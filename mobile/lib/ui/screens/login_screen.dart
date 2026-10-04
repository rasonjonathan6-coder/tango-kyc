/// Sign-in screen.
///
/// Premium dark presentation: a near-black canvas lit by magenta/violet/blue
/// halos, the brand lockup, a two-line gradient title, glassy neon fields, the
/// rose→violet→electric primary action, Google sign-in and the two secondary
/// entry points (passwordless code, account creation).
///
/// Presentation only. Every handler below is the pre-existing one — the same
/// [AuthController] calls, the same validators, the same routes — so the visual
/// overhaul changed nothing about how authentication works.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/validators.dart';
import '../../services/auth_service.dart';
import '../../state/auth_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/aurora.dart';
import '../widgets/auth_kit.dart';
import '../widgets/tango_scaffold.dart';
import 'register_screen.dart';
import 'forgot_password_screen.dart';
import 'otp_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final auth = context.read<AuthController>();
    final ok = await auth.signIn(
      email: Validators.normalize(_emailController.text),
      password: _passwordController.text,
    );

    if (!mounted) return;
    if (!ok) {
      _showError(ErrorMessages.from(auth.lastError ?? ''));
    }
  }

  Future<void> _google() async {
    final auth = context.read<AuthController>();
    final ok = await auth.signInWithGoogle();
    if (!mounted || ok) return;
    _showError(ErrorMessages.from(auth.lastError ?? ''));
  }

  /// Starts the passwordless code flow for the address typed above.
  ///
  /// The code is requested *before* navigating, so a rejected request — rate
  /// limit, mailer not configured, no connection — is reported on the form the
  /// user is already on, instead of behind a code-entry screen that could never
  /// be satisfied. The email field doubles as the destination, so the user is
  /// nudged to fill it rather than being shown an empty second form.
  Future<void> _startCodeSignIn() async {
    final email = Validators.normalize(_emailController.text);
    if (email.isEmpty || Validators.validateEmail(email) != null) {
      _showError('Saisissez d’abord votre adresse email ci-dessus.');
      return;
    }

    final auth = context.read<AuthController>();
    final sent = await auth.sendEmailOtp(
      email: email,
      purpose: EmailOtpPurpose.signup,
    );
    if (!mounted) return;
    if (!sent) {
      _showError(ErrorMessages.from(auth.lastError ?? ''));
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            OtpScreen(email: email, purpose: EmailOtpPurpose.signup),
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.errorContainer,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();

    return AuthBackground(
      child: TangoKycScaffold(
        body: Center(
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Reveal(child: Center(child: BrandLockup())),
                    const SizedBox(height: 12),
                    const Reveal(
                      delay: Duration(milliseconds: 50),
                      child: _Title(),
                    ),
                    const SizedBox(height: 8),
                    const Reveal(
                      delay: Duration(milliseconds: 80),
                      child: _Subtitle(),
                    ),
                    const SizedBox(height: 14),
                    Reveal(
                      delay: const Duration(milliseconds: 110),
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
                    const SizedBox(height: 12),
                    Reveal(
                      delay: const Duration(milliseconds: 140),
                      child: NeonField(
                        label: 'Mot de passe',
                        controller: _passwordController,
                        hint: 'Votre mot de passe',
                        icon: Icons.lock_rounded,
                        obscureText: _obscure,
                        enabled: !auth.busy,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.password],
                        onSubmitted: (_) => _submit(),
                        validator: (value) => (value ?? '').isEmpty
                            ? 'Veuillez saisir votre mot de passe.'
                            : null,
                        suffix: _EyeToggle(
                          obscure: _obscure,
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                    ),
                    Reveal(
                      delay: const Duration(milliseconds: 160),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: auth.busy
                              ? null
                              : () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        const ForgotPasswordScreen(),
                                  ),
                                ),
                          iconAlignment: IconAlignment.end,
                          icon: const Icon(
                            Icons.chevron_right_rounded,
                            size: 18,
                          ),
                          label: const Text('Mot de passe oublié ?'),
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 36),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            foregroundColor: AppColors.magenta,
                            textStyle: const TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Reveal(
                      delay: const Duration(milliseconds: 190),
                      child: GradientButton(
                        onPressed: auth.busy ? null : _submit,
                        busy: auth.busy,
                        height: 64,
                        radius: 34,
                        gradient: AppTheme.actionGradient,
                        icon: Icons.login_rounded,
                        textStyle: const TextStyle(
                          color: Colors.white,
                          fontSize: 18.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                        child: const Text('Se connecter'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Reveal(
                      delay: Duration(milliseconds: 220),
                      child: OrDivider(),
                    ),
                    const SizedBox(height: 10),
                    Reveal(
                      delay: const Duration(milliseconds: 250),
                      child: _GoogleCard(
                        enabled: !auth.busy,
                        onPressed: _google,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Reveal(
                      delay: const Duration(milliseconds: 280),
                      child: _SecondaryOptions(
                        enabled: !auth.busy,
                        onCode: _startCodeSignIn,
                        onRegister: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const RegisterScreen(),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Reveal(
                      delay: Duration(milliseconds: 310),
                      child: AuthFooter(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The gradient two-line title, wrapping naturally on narrow screens.
///
/// Shares [AuthHeading] with the other auth pages so the lockup, weight and
/// accent treatment cannot drift between Login, Register and Forgot Password.
class _Title extends StatelessWidget {
  const _Title();

  @override
  Widget build(BuildContext context) {
    return const AuthHeading(
      lines: [
        [HeadingSegment('Tango'), HeadingSegment('KYC', gradient: true)],
        [HeadingSegment('Vérification')],
      ],
    );
  }
}

class _Subtitle extends StatelessWidget {
  const _Subtitle();

  @override
  Widget build(BuildContext context) {
    return Text(
      'Vérifiez votre compte pour profiter\nde toutes les fonctionnalités.',
      textAlign: TextAlign.center,
      style: TextStyle(
        // Slightly blue-white, per the reference description colour.
        color: context.tokens.textSecondary.withValues(alpha: 0.92),
        fontSize: 17,
        height: 1.4,
        fontWeight: FontWeight.w400,
      ),
    );
  }
}

/// The eye affordance on the password field, sized for a comfortable tap target.
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

class _GoogleCard extends StatelessWidget {
  const _GoogleCard({required this.enabled, required this.onPressed});

  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GlassActionCard(
      onTap: onPressed,
      enabled: enabled,
      height: 58,
      radius: 30,
      child: Row(
        children: [
          const GoogleGlyph(size: 24),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              'Continuer avec Google',
              style: TextStyle(
                color: context.tokens.textPrimary,
                fontSize: 15.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            size: 22,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

/// The two secondary entries: passwordless code and account creation.
///
/// Two columns when the width allows, stacked when it does not.
class _SecondaryOptions extends StatelessWidget {
  const _SecondaryOptions({
    required this.enabled,
    required this.onCode,
    required this.onRegister,
  });

  final bool enabled;
  final VoidCallback onCode;
  final VoidCallback onRegister;

  @override
  Widget build(BuildContext context) {
    final code = _OptionCard(
      icon: Icons.qr_code_2_rounded,
      prompt: 'Préférer un code ?',
      action: 'Se connecter avec un code',
      enabled: enabled,
      onTap: onCode,
    );
    final register = _OptionCard(
      icon: Icons.person_add_alt_1_rounded,
      prompt: 'Nouveau ici ?',
      action: 'Créer un compte',
      enabled: enabled,
      onTap: onRegister,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // 300dp is roughly two comfortable cards plus the gap; below that they
        // stack so the labels never get squeezed.
        if (constraints.maxWidth >= 300) {
          // IntrinsicHeight lets the two cards share the taller card's height
          // without asking the scroll view for an unbounded one.
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: code),
                const SizedBox(width: 12),
                Expanded(child: register),
              ],
            ),
          );
        }
        return Column(children: [code, const SizedBox(height: 12), register]);
      },
    );
  }
}

class _OptionCard extends StatelessWidget {
  const _OptionCard({
    required this.icon,
    required this.prompt,
    required this.action,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String prompt;
  final String action;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return GlassActionCard(
      onTap: onTap,
      enabled: enabled,
      radius: 26,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 22, color: AppColors.violetBright),
          const SizedBox(height: 10),
          Text(
            prompt,
            style: TextStyle(color: muted, fontSize: 12.5, height: 1.2),
          ),
          const SizedBox(height: 3),
          Text(
            action,
            style: TextStyle(
              color: context.tokens.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }
}

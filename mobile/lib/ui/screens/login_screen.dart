/// Sign-in screen.
///
/// Follows the product artwork: an animated aurora canvas, the brand mark, the
/// email/password pair, the gradient primary action, Google sign-in and the two
/// secondary entry points (passwordless code, account creation).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/validators.dart';
import '../../services/auth_service.dart';
import '../../state/auth_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/aurora.dart';
import '../widgets/common.dart';
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
  /// The email field doubles as the destination, so the user is nudged to fill
  /// it rather than being shown an empty second form.
  Future<void> _startCodeSignIn() async {
    final email = Validators.normalize(_emailController.text);
    if (email.isEmpty || Validators.validateEmail(email) != null) {
      _showError('Saisissez d’abord votre adresse email ci-dessus.');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OtpScreen(email: email, purpose: EmailOtpPurpose.signup),
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Theme.of(context).colorScheme.errorContainer),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AuroraBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Reveal(child: _Header()),
                      const SizedBox(height: 30),
                      Reveal(
                        delay: const Duration(milliseconds: 60),
                        child: LabeledField(
                          label: 'Email',
                          controller: _emailController,
                          hint: 'vous@exemple.com',
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.email],
                          enabled: !auth.busy,
                          validator: Validators.validateEmail,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Reveal(
                        delay: const Duration(milliseconds: 90),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Mot de passe',
                                style: theme.textTheme.labelLarge
                                    ?.copyWith(fontWeight: FontWeight.w600)),
                            const SizedBox(height: 8),
                            TextFormField(
                              controller: _passwordController,
                              obscureText: _obscure,
                              enabled: !auth.busy,
                              textInputAction: TextInputAction.done,
                              autofillHints: const [AutofillHints.password],
                              onFieldSubmitted: (_) => _submit(),
                              validator: (value) => (value ?? '').isEmpty
                                  ? 'Veuillez saisir votre mot de passe.'
                                  : null,
                              decoration: InputDecoration(
                                hintText: 'Votre mot de passe',
                                suffixIcon: IconButton(
                                  icon: Icon(_obscure
                                      ? Icons.visibility_off_rounded
                                      : Icons.visibility_rounded),
                                  onPressed: () => setState(() => _obscure = !_obscure),
                                  tooltip: _obscure ? 'Afficher' : 'Masquer',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: auth.busy
                              ? null
                              : () => Navigator.of(context).push(
                                    MaterialPageRoute(builder: (_) => const ForgotPasswordScreen()),
                                  ),
                          child: const Text('Mot de passe oublié ?'),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Reveal(
                        delay: const Duration(milliseconds: 120),
                        child: GradientButton(
                          onPressed: auth.busy ? null : _submit,
                          busy: auth.busy,
                          child: const Text('Se connecter'),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Reveal(
                        delay: const Duration(milliseconds: 150),
                        child: Row(
                          children: [
                            const Expanded(child: Divider()),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              child: Text('ou', style: theme.textTheme.bodySmall),
                            ),
                            const Expanded(child: Divider()),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Reveal(
                        delay: const Duration(milliseconds: 180),
                        child: OutlinedButton.icon(
                          onPressed: auth.busy ? null : _google,
                          icon: const Icon(Icons.g_mobiledata_rounded, size: 28),
                          label: const Text('Continuer avec Google'),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Reveal(
                        delay: const Duration(milliseconds: 210),
                        child: _SecondaryRow(
                          prompt: 'Préférer un code ?',
                          action: 'Se connecter avec un code',
                          onPressed: auth.busy ? null : _startCodeSignIn,
                        ),
                      ),
                      Reveal(
                        delay: const Duration(milliseconds: 240),
                        child: _SecondaryRow(
                          prompt: 'Nouveau ici ?',
                          action: 'Créer un compte',
                          onPressed: auth.busy
                              ? null
                              : () => Navigator.of(context).push(
                                    MaterialPageRoute(builder: (_) => const RegisterScreen()),
                                  ),
                        ),
                      ),
                      const SizedBox(height: 26),
                      const Reveal(
                        delay: Duration(milliseconds: 280),
                        child: _Footer(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Brand mark, wordmark and one-line value proposition.
class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        const LogoMark(size: 78),
        const SizedBox(height: 22),
        ShaderMask(
          shaderCallback: (bounds) => AppTheme.brandGradient.createShader(bounds),
          child: Text(
            'Tango KYC Verification',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Vérifiez votre compte pour profiter de toutes les fonctionnalités.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// "Prompt? action" pair rendered as a centred, wrapping row.
class _SecondaryRow extends StatelessWidget {
  const _SecondaryRow({
    required this.prompt,
    required this.action,
    required this.onPressed,
  });

  final String prompt;
  final String action;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Flexible(
          child: Text(prompt, style: theme.textTheme.bodyMedium, overflow: TextOverflow.ellipsis),
        ),
        Flexible(
          child: TextButton(
            onPressed: onPressed,
            child: Text(action, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
    );
  }
}

/// Closing tagline, kept visually quiet.
class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.auto_awesome_rounded, size: 14, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            'Tango - Plus qu’une app, une communauté',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

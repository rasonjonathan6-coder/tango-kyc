/// Requests a password reset email. The email link returns to the app through
/// the configured deep link and lands on the reset screen.
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
import 'otp_screen.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  bool _sent = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final auth = context.read<AuthController>();
    final ok = await auth.sendPasswordReset(
      Validators.normalize(_emailController.text),
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
    setState(() => _sent = true);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();

    if (_sent) {
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
                  icon: Icons.outgoing_mail,
                ),
              ),
              const SizedBox(height: 20),
              Reveal(
                delay: const Duration(milliseconds: 90),
                child: Text(
                  'Email envoyé',
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
                  'Si ${Validators.normalize(_emailController.text)} possède un compte, '
                  'un lien de réinitialisation est en route. Ouvrez-le sur cet appareil '
                  'pour choisir un nouveau mot de passe.',
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 30),
              Reveal(
                delay: const Duration(milliseconds: 160),
                child: GradientButton(
                  onPressed: auth.busy
                      ? null
                      : () => Navigator.of(context).pushReplacement(
                          MaterialPageRoute(
                            builder: (_) => OtpScreen(
                              email: Validators.normalize(
                                _emailController.text,
                              ),
                              purpose: EmailOtpPurpose.recovery,
                            ),
                          ),
                        ),
                  height: 60,
                  radius: 32,
                  gradient: AppTheme.actionGradient,
                  icon: Icons.sms_outlined,
                  child: const Text('Recevoir un code à la place'),
                ),
              ),
              const SizedBox(height: 10),
              Reveal(
                delay: const Duration(milliseconds: 200),
                child: Center(
                  child: AuthTextLink(
                    label: 'Retour à la connexion',
                    color: AppColors.magenta,
                    onPressed: auth.busy
                        ? null
                        : () => Navigator.of(context).pop(),
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
                  [HeadingSegment('Mot de passe')],
                  [HeadingSegment('oublié ?', gradient: true)],
                ],
              ),
            ),
            const SizedBox(height: 10),
            Reveal(
              delay: const Duration(milliseconds: 80),
              child: AuthSubtitle(
                'Entrez votre adresse email pour recevoir\nun lien de réinitialisation.',
              ),
            ),
            const SizedBox(height: 24),
            Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Reveal(
                    delay: const Duration(milliseconds: 120),
                    child: NeonField(
                      label: 'Email',
                      controller: _emailController,
                      hint: 'vous@exemple.com',
                      icon: Icons.alternate_email_rounded,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.email],
                      enabled: !auth.busy,
                      validator: Validators.validateEmail,
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Reveal(
                    delay: const Duration(milliseconds: 170),
                    child: GradientButton(
                      onPressed: auth.busy ? null : _submit,
                      busy: auth.busy,
                      height: 62,
                      radius: 32,
                      gradient: AppTheme.actionGradient,
                      icon: Icons.mark_email_read_outlined,
                      child: const Text('Envoyer le lien'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Reveal(
                    delay: const Duration(milliseconds: 210),
                    child: Center(
                      child: AuthTextLink(
                        label: 'Retour à la connexion',
                        color: AppColors.magenta,
                        onPressed: auth.busy
                            ? null
                            : () => Navigator.of(context).pop(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Reveal(
                    delay: Duration(milliseconds: 240),
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

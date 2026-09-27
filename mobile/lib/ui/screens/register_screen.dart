/// Registration screen. When Supabase requires email confirmation the account is
/// created without a session and the user is told to check their inbox rather
/// than being dropped into a signed-in state that does not exist.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/validators.dart';
import '../../services/auth_service.dart';
import '../../state/auth_controller.dart';
import '../widgets/common.dart';
import 'otp_screen.dart';

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
    // immediately signing the user in. The mail carries both a link and a code;
    // offer the code so the user can finish inside the app.
    if (auth.isSignedIn) {
      Navigator.of(context).pop();
    } else {
      final codeSent = await auth.sendEmailOtp(
        email: email,
        purpose: EmailOtpPurpose.signup,
      );
      if (!mounted) return;
      if (codeSent) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => OtpScreen(email: email, purpose: EmailOtpPurpose.signup),
          ),
        );
      } else {
        // The code could not be requested, but the confirmation link still
        // works, so fall back to the link instructions rather than failing.
        setState(() => _awaitingConfirmation = true);
      }
    }
  }

  Future<void> _resend() async {
    final auth = context.read<AuthController>();
    final ok = await auth.resendConfirmation(Validators.normalize(_emailController.text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? 'Confirmation email sent.'
            : ErrorMessages.from(auth.lastError ?? '')),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final theme = Theme.of(context);

    if (_awaitingConfirmation) {
      return Scaffold(
        appBar: AppBar(title: const Text('Confirm your email')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              Icon(Icons.mark_email_unread_rounded, size: 64, color: theme.colorScheme.primary),
              const SizedBox(height: 24),
              Text(
                'Check your inbox',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Text(
                'We sent a confirmation link to ${Validators.normalize(_emailController.text)}. '
                'Open it to activate your account, then sign in.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 32),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Back to sign in'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: auth.busy ? null : _resend,
                child: const Text('Resend confirmation email'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Create an account')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Create your account to submit and track a manual KYC review request.',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 26),
                    LabeledField(
                      label: 'Full name (optional)',
                      controller: _nameController,
                      hint: 'Your name',
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.name],
                      enabled: !auth.busy,
                    ),
                    const SizedBox(height: 18),
                    LabeledField(
                      label: 'Email',
                      controller: _emailController,
                      hint: 'you@example.com',
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.email],
                      enabled: !auth.busy,
                      validator: Validators.validateEmail,
                    ),
                    const SizedBox(height: 18),
                    LabeledField(
                      label: 'Password',
                      controller: _passwordController,
                      hint: 'At least 8 characters',
                      obscureText: _obscure,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.newPassword],
                      enabled: !auth.busy,
                      validator: Validators.validatePassword,
                      suffix: IconButton(
                        icon: Icon(_obscure ? Icons.visibility_off_rounded : Icons.visibility_rounded),
                        onPressed: () => setState(() => _obscure = !_obscure),
                        tooltip: _obscure ? 'Show password' : 'Hide password',
                      ),
                    ),
                    const SizedBox(height: 18),
                    LabeledField(
                      label: 'Confirm password',
                      controller: _confirmController,
                      hint: 'Repeat your password',
                      obscureText: _obscure,
                      textInputAction: TextInputAction.done,
                      enabled: !auth.busy,
                      validator: (value) => Validators.validatePasswordConfirmation(
                        _passwordController.text,
                        value,
                      ),
                      onSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: 28),
                    FilledButton(
                      onPressed: auth.busy ? null : _submit,
                      child: auth.busy
                          ? const SizedBox(
                              height: 22,
                              width: 22,
                              child: CircularProgressIndicator(strokeWidth: 2.4),
                            )
                          : const Text('Create account'),
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

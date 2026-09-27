/// Requests a password reset email. The email link returns to the app through
/// the configured deep link and lands on the reset screen.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/validators.dart';
import '../../services/auth_service.dart';
import '../../state/auth_controller.dart';
import '../widgets/common.dart';
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
    final ok = await auth.sendPasswordReset(Validators.normalize(_emailController.text));

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
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Reset password')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: _sent
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 32),
                        Icon(Icons.outgoing_mail, size: 60, color: theme.colorScheme.primary),
                        const SizedBox(height: 22),
                        Text(
                          'Reset email sent',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'If ${Validators.normalize(_emailController.text)} has an account, '
                          'a password reset link is on its way. Open it on this device to choose '
                          'a new password.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 30),
                        FilledButton(
                          onPressed: auth.busy
                              ? null
                              : () => Navigator.of(context).pushReplacement(
                                    MaterialPageRoute(
                                      builder: (_) => OtpScreen(
                                        email: Validators.normalize(_emailController.text),
                                        purpose: EmailOtpPurpose.recovery,
                                      ),
                                    ),
                                  ),
                          child: const Text('Enter a code instead'),
                        ),
                        const SizedBox(height: 10),
                        OutlinedButton(
                          onPressed: auth.busy ? null : () => Navigator.of(context).pop(),
                          child: const Text('Back to sign in'),
                        ),
                      ],
                    )
                  : Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Enter the email address on your account and we will send you a link '
                            'to choose a new password.',
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                          const SizedBox(height: 26),
                          LabeledField(
                            label: 'Email',
                            controller: _emailController,
                            hint: 'you@example.com',
                            keyboardType: TextInputType.emailAddress,
                            textInputAction: TextInputAction.done,
                            autofillHints: const [AutofillHints.email],
                            enabled: !auth.busy,
                            validator: Validators.validateEmail,
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
                                : const Text('Send reset link'),
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

/// Sign-in screen: email + password, Google sign-in, and links to register and
/// to recover a forgotten password.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/validators.dart';
import '../../state/auth_controller.dart';
import '../widgets/common.dart';
import 'register_screen.dart';
import 'forgot_password_screen.dart';

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
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: AnimatedEntry(
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Header(theme: theme),
                      const SizedBox(height: 32),
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
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Password',
                              style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _passwordController,
                            obscureText: _obscure,
                            enabled: !auth.busy,
                            textInputAction: TextInputAction.done,
                            autofillHints: const [AutofillHints.password],
                            onFieldSubmitted: (_) => _submit(),
                            validator: (value) =>
                                (value ?? '').isEmpty ? 'Please enter your password.' : null,
                            decoration: InputDecoration(
                              hintText: 'Your password',
                              suffixIcon: IconButton(
                                icon: Icon(_obscure
                                    ? Icons.visibility_off_rounded
                                    : Icons.visibility_rounded),
                                onPressed: () => setState(() => _obscure = !_obscure),
                                tooltip: _obscure ? 'Show password' : 'Hide password',
                              ),
                            ),
                          ),
                        ],
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: auth.busy
                              ? null
                              : () => Navigator.of(context).push(
                                    MaterialPageRoute(builder: (_) => const ForgotPasswordScreen()),
                                  ),
                          child: const Text('Forgot password?'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed: auth.busy ? null : _submit,
                        child: auth.busy
                            ? const SizedBox(
                                height: 22,
                                width: 22,
                                child: CircularProgressIndicator(strokeWidth: 2.4),
                              )
                            : const Text('Sign in'),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          const Expanded(child: Divider()),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text('or', style: theme.textTheme.bodySmall),
                          ),
                          const Expanded(child: Divider()),
                        ],
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: auth.busy ? null : _google,
                        icon: const Icon(Icons.g_mobiledata_rounded, size: 28),
                        label: const Text('Continue with Google'),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('New here?', style: theme.textTheme.bodyMedium),
                          TextButton(
                            onPressed: auth.busy
                                ? null
                                : () => Navigator.of(context).push(
                                      MaterialPageRoute(builder: (_) => const RegisterScreen()),
                                    ),
                            child: const Text('Create an account'),
                          ),
                        ],
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

class _Header extends StatelessWidget {
  const _Header({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 68,
          width: 68,
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Icon(Icons.verified_user_rounded, size: 36, color: theme.colorScheme.onPrimaryContainer),
        ),
        const SizedBox(height: 20),
        Text(
          'Tango KYC Verification',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          'Request a manual review of your KYC verification.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

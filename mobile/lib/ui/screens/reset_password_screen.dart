/// Sets a new password for the session established by a recovery link.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/validators.dart';
import '../../state/auth_controller.dart';
import '../widgets/common.dart';

class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({super.key});

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final auth = context.read<AuthController>();
    final ok = await auth.updatePassword(_passwordController.text);

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

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Password updated.')),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Choose a new password')),
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
                      'Choose a new password for your account.',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 26),
                    LabeledField(
                      label: 'New password',
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
                      label: 'Confirm new password',
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
                          : const Text('Update password'),
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

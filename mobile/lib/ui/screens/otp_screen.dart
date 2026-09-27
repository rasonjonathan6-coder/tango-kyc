/// Email one-time-code entry.
///
/// Shared by the two flows that need it:
///
/// * [EmailOtpPurpose.signup] — confirming a freshly created account so the
///   user ends up signed in instead of following a link.
/// * [EmailOtpPurpose.recovery] — proving ownership before a new password is set.
///
/// The code is verified against Supabase; nothing here is mocked. A successful
/// verification establishes a real session, which `AuthController` observes and
/// the root gate acts on.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/validators.dart';
import '../../services/auth_service.dart';
import '../../state/auth_controller.dart';
import '../widgets/aurora.dart';
import 'reset_password_screen.dart';

/// How many digits Supabase currently mails for this project.
///
/// Read from the live project configuration (`mailer_otp_length = 8`), not from
/// the six-digit default, so the input length matches the code that arrives.
const int kEmailOtpLength = 8;

/// Cooldown before the resend action is offered again.
///
/// This is a client-side courtesy only; the authoritative limit is the
/// project's per-hour email quota, which the server enforces.
const Duration kOtpResendCooldown = Duration(seconds: 60);

class OtpScreen extends StatefulWidget {
  const OtpScreen({
    super.key,
    required this.email,
    required this.purpose,
    this.resendCooldown = kOtpResendCooldown,
  });

  final String email;
  final EmailOtpPurpose purpose;

  /// Overridable so widget tests can disable the countdown instead of waiting on
  /// a live [Timer].
  final Duration resendCooldown;

  bool get isRecovery => purpose == EmailOtpPurpose.recovery;

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  final _codeController = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _ticker;
  int _secondsLeft = kOtpResendCooldown.inSeconds;
  String? _error;
  int _failedAttempts = 0;

  @override
  void initState() {
    super.initState();
    _startCooldown();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _focusNode.requestFocus(),
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _codeController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _ticker?.cancel();
    if (widget.resendCooldown == Duration.zero) {
      // Test mode: no countdown and, importantly, no pending timer.
      _secondsLeft = 0;
      return;
    }
    setState(() => _secondsLeft = widget.resendCooldown.inSeconds);
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_secondsLeft <= 1) {
        timer.cancel();
        setState(() => _secondsLeft = 0);
      } else {
        setState(() => _secondsLeft--);
      }
    });
  }

  bool get _isComplete => _codeController.text.length == kEmailOtpLength;

  Future<void> _verify() async {
    FocusScope.of(context).unfocus();
    final code = _codeController.text.trim();
    if (code.length != kEmailOtpLength) {
      setState(
        () => _error =
            'Saisissez le code à $kEmailOtpLength chiffres reçu par email.',
      );
      return;
    }

    final auth = context.read<AuthController>();
    final ok = await auth.verifyEmailOtp(
      email: widget.email,
      token: code,
      purpose: widget.purpose,
    );
    if (!mounted) return;

    if (!ok) {
      setState(() {
        _failedAttempts++;
        _error = ErrorMessages.from(auth.lastError ?? '');
      });
      _codeController.clear();
      _focusNode.requestFocus();
      return;
    }

    // The session now exists. Recovery still needs a new password; a signup
    // code is complete on its own and the root gate takes over.
    if (widget.isRecovery) {
      // A recovery code only proves ownership; the password still has to change.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ResetPasswordScreen()),
      );
    } else {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  Future<void> _resend() async {
    if (_secondsLeft > 0) return;
    final auth = context.read<AuthController>();
    final ok = await auth.resendEmailOtp(
      email: widget.email,
      purpose: widget.purpose,
    );
    if (!mounted) return;

    if (!ok) {
      setState(() => _error = ErrorMessages.from(auth.lastError ?? ''));
      return;
    }
    _codeController.clear();
    setState(() {
      _error = null;
      _failedAttempts = 0;
    });
    _startCooldown();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Un nouveau code est en route.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final theme = Theme.of(context);
    final busy = auth.busy;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(
          widget.isRecovery
              ? 'Vérifiez votre identité'
              : 'Confirmez votre email',
        ),
      ),
      body: AuroraBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 8),
                    const LogoMark(
                      size: 68,
                      animate: false,
                      iconSize: 34,
                      icon: Icons.lock_person_rounded,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Entrez votre code',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Nous avons envoyé un code à $kEmailOtpLength chiffres à ${widget.email}. '
                      'Saisissez-le ci-dessous pour continuer.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 28),
                    TextField(
                      controller: _codeController,
                      focusNode: _focusNode,
                      enabled: !busy,
                      autofocus: false,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.done,
                      textAlign: TextAlign.center,
                      autofillHints: const [AutofillHints.oneTimeCode],
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(kEmailOtpLength),
                      ],
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: 10,
                      ),
                      onChanged: (_) {
                        if (_error != null) setState(() => _error = null);
                        setState(() {});
                      },
                      onSubmitted: (_) =>
                          _isComplete && !busy ? _verify() : null,
                      decoration: InputDecoration(
                        hintText: '0' * kEmailOtpLength,
                        hintStyle: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 10,
                          color: theme.colorScheme.outlineVariant,
                        ),
                        errorText: _error,
                        counterText: '',
                      ),
                    ),
                    if (_failedAttempts > 0) ...[
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 18,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Les codes expirent au bout d’une heure. S’il a expiré, demandez-en un nouveau.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 28),
                    GradientButton(
                      onPressed: busy || !_isComplete ? null : _verify,
                      busy: busy,
                      child: const Text('Vérifier le code'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: (busy || _secondsLeft > 0) ? null : _resend,
                      child: Text(
                        _secondsLeft > 0
                            ? 'Renvoyer le code dans ${_secondsLeft}s'
                            : 'Renvoyer le code',
                      ),
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

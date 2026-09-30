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
import '../theme/app_theme.dart';
import '../widgets/aurora.dart';
import '../widgets/auth_kit.dart';
import '../widgets/tango_scaffold.dart';
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

  /// Formats the resend cooldown as `MM:SS`, matching the artwork.
  String _mmss(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final busy = auth.busy;

    return TangoKycScaffold(
      body: AuthScreenLayout(
        children: [
          const Reveal(child: Center(child: BrandLockup())),
          const SizedBox(height: 14),
          const Reveal(
            delay: Duration(milliseconds: 50),
            child: AuthHeading(
              lines: [
                [HeadingSegment('Vérifiez')],
                [HeadingSegment('votre email', gradient: true)],
              ],
            ),
          ),
          const SizedBox(height: 10),
          Reveal(
            delay: const Duration(milliseconds: 80),
            child: Text(
              'Nous avons envoyé un code de vérification à\n${widget.email}',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.tokens.textSecondary.withValues(alpha: 0.92),
                fontSize: 16,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 26),
          Reveal(
            delay: const Duration(milliseconds: 120),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final tile = ((constraints.maxWidth - (kEmailOtpLength - 1) * 8) /
                        kEmailOtpLength)
                    .clamp(26.0, 42.0);
                final digits = _codeController.text;
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    // The tiles render the digits; the real field is transparent
                    // on top and keeps every behaviour it already had.
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < kEmailOtpLength; i++) ...[
                          if (i > 0) const SizedBox(width: 8),
                          GhostTile(
                            filled: i < digits.length,
                            char: i < digits.length ? digits[i] : '',
                            size: tile,
                          ),
                        ],
                      ],
                    ),
                    SizedBox(
                      width: kEmailOtpLength * (tile + 8),
                      height: tile + 14,
                      child: TextField(
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
                        style: const TextStyle(
                          color: Colors.transparent,
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                        ),
                        cursorColor: AppColors.cyan,
                        cursorWidth: 2,
                        onChanged: (_) {
                          if (_error != null) setState(() => _error = null);
                          setState(() {});
                        },
                        onSubmitted: (_) =>
                            _isComplete && !busy ? _verify() : null,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          errorBorder: InputBorder.none,
                          focusedErrorBorder: InputBorder.none,
                          counterText: '',
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Reveal(
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFFFF8FA8),
                  fontSize: 13,
                  height: 1.3,
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Reveal(
            delay: const Duration(milliseconds: 150),
            child: Text(
              'Le code comporte $kEmailOtpLength chiffres.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: context.tokens.textSecondary.withValues(alpha: 0.7),
                fontSize: 13.5,
              ),
            ),
          ),
          if (_failedAttempts > 0) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 18,
                  color: context.tokens.textSecondary.withValues(alpha: 0.8),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Les codes expirent au bout d’une heure. S’il a expiré, demandez-en un nouveau.',
                    style: TextStyle(
                      color: context.tokens.textSecondary.withValues(alpha: 0.8),
                      fontSize: 12.5,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 26),
          Reveal(
            delay: const Duration(milliseconds: 190),
            child: GradientButton(
              onPressed: busy || !_isComplete ? null : _verify,
              busy: busy,
              height: 62,
              radius: 32,
              gradient: AppTheme.actionGradient,
              icon: Icons.verified_rounded,
              child: const Text('Vérifier le code'),
            ),
          ),
          const SizedBox(height: 12),
          Reveal(
            delay: const Duration(milliseconds: 230),
            child: Center(
              child: AuthTextLink(
                label: _secondsLeft > 0
                    ? 'Renvoyer le code (${_mmss(_secondsLeft)})'
                    : 'Renvoyer le code',
                color: AppColors.magenta,
                onPressed: (busy || _secondsLeft > 0) ? null : _resend,
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Reveal(
            delay: Duration(milliseconds: 260),
            child: AuthFooter(),
          ),
        ],
      ),
    );
  }
}

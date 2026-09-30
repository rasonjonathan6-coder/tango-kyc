/// The notification-permission prompt, matching the reference artwork's screen
/// 17.
///
/// It drives the **real** Android permission through [PushService]:
///
///   * on open it *reads* the current state with `notificationPermission()` and
///     immediately dismisses itself when the answer is already `granted`, so the
///     screen is never shown unnecessarily;
///   * "Autoriser" calls `requestNotificationPermission()` once;
///   * "Plus tard" calls `onSkip` without ever prompting.
///
/// The caller is responsible for not routing here again after a refusal: this
/// screen tracks that itself (see [NotificationPermissionScreen.shouldShow]) and
/// the settings store persists the answer.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/notification_service.dart';
import '../theme/app_theme.dart';
import '../widgets/aurora.dart';
import '../widgets/tango_scaffold.dart';

class NotificationPermissionScreen extends StatefulWidget {
  const NotificationPermissionScreen({
    super.key,
    required this.onDone,
  });

  /// Called with the final permission state, once, whatever the user chose.
  final void Function(NotificationPermission) onDone;

  /// Whether the prompt is worth showing at all.
  ///
  /// Returns false when Firebase is unavailable or the permission is already
  /// granted — in both cases prompting would be pointless or annoying.
  static Future<bool> shouldShow(PushService push) async {
    final current = await push.notificationPermission();
    return current == NotificationPermission.denied;
  }

  @override
  State<NotificationPermissionScreen> createState() =>
      _NotificationPermissionScreenState();
}

class _NotificationPermissionScreenState
    extends State<NotificationPermissionScreen> {
  bool _busy = false;
  bool _resolved = false;

  @override
  void initState() {
    super.initState();
    // If the permission was granted while we were away, don't nag: resolve at
    // once. This is the "never ask in a loop" guarantee.
    WidgetsBinding.instance.addPostFrameCallback((_) => _dismissIfAlreadyGranted());
  }

  Future<void> _dismissIfAlreadyGranted() async {
    if (_resolved || !mounted) return;
    final push = _push();
    if (push == null) return;
    final current = await push.notificationPermission();
    if (!mounted || _resolved) return;
    if (current != NotificationPermission.denied) {
      _resolved = true;
      widget.onDone(current);
    }
  }

  PushService? _push() {
    try {
      return Provider.of<PushService>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  Future<void> _allow() async {
    final push = _push();
    if (push == null) {
      _finish(NotificationPermission.unavailable);
      return;
    }
    setState(() => _busy = true);
    final result = await push.requestNotificationPermission();
    if (!mounted) return;
    setState(() => _busy = false);
    _finish(result);
  }

  void _finish(NotificationPermission result) {
    if (_resolved) return;
    _resolved = true;
    widget.onDone(result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return TangoKycScaffold(
      safeArea: false,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(26, 24, 26, 22),
          child: Column(
            children: [
              const Spacer(),
              Reveal(
                child: Center(
                  child: Container(
                    height: 118,
                    width: 118,
                    decoration: BoxDecoration(
                      gradient: AppTheme.actionGradient,
                      borderRadius: BorderRadius.circular(38),
                      boxShadow: AppTheme.glow(
                        AppColors.violet,
                        opacity: 0.45,
                        blur: 34,
                      ),
                    ),
                    child: const Icon(
                      Icons.notifications_active_rounded,
                      size: 58,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 34),
              Reveal(
                delay: const Duration(milliseconds: 70),
                child: Text(
                  'Autoriser les notifications ?',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Reveal(
                delay: const Duration(milliseconds: 110),
                child: Text(
                  'Recevez des alertes pour vos tickets, vos réponses et les '
                  'mises à jour importantes.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.55,
                  ),
                ),
              ),
              const Spacer(),
              Reveal(
                delay: const Duration(milliseconds: 150),
                child: GradientButton(
                  onPressed: _busy ? null : _allow,
                  busy: _busy,
                  height: 56,
                  radius: 30,
                  child: const Text('Autoriser'),
                ),
              ),
              const SizedBox(height: 10),
              Reveal(
                delay: const Duration(milliseconds: 180),
                child: TextButton(
                  onPressed: _busy
                      ? null
                      : () => _finish(NotificationPermission.denied),
                  style: TextButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: const Text('Plus tard'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

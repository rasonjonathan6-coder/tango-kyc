/// Splash: shows branding while the persisted session is restored.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.85, end: 1),
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOutBack,
              builder: (context, value, child) => Transform.scale(scale: value, child: child),
              child: Container(
                height: 92,
                width: 92,
                decoration: BoxDecoration(
                  gradient: AppTheme.heroGradient(theme.brightness),
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: theme.brightness == Brightness.dark
                      ? null
                      : const [
                          BoxShadow(
                            color: Color(0x332F6B5F),
                            blurRadius: 26,
                            offset: Offset(0, 12),
                          ),
                        ],
                ),
                child: const Icon(
                  Icons.verified_user_rounded,
                  size: 46,
                  color: AppTheme.onHero,
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Tango KYC Verification',
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 28),
            const SizedBox(
              height: 22,
              width: 22,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            if (message != null) ...[
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

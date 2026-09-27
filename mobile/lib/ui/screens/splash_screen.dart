/// Splash: shows branding while the persisted session is restored.
library;

import 'package:flutter/material.dart';

import '../widgets/aurora.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AuroraBackground(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.85, end: 1),
                duration: const Duration(milliseconds: 600),
                curve: Curves.easeOutBack,
                builder: (context, value, child) =>
                    Transform.scale(scale: value, child: child),
                child: const LogoMark(size: 92, animate: false, iconSize: 46),
              ),
              const SizedBox(height: 24),
              Text(
                'Tango KYC Verification',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
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
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

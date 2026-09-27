/// First-run onboarding: three concise pages that explain what the app does and
/// what the manual KYC review involves, before the user reaches sign-in.
///
/// Shown once; the choice is persisted so returning users go straight to login.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/aurora.dart';

/// One onboarding page.
class _Page {
  const _Page({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;
}

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onFinished});

  /// Called when the user finishes or skips; the caller persists the choice.
  final VoidCallback onFinished;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _index = 0;

  static const _pages = [
    _Page(
      icon: Icons.verified_user_rounded,
      title: 'Vérification manuelle',
      body: 'Demandez à l’équipe support Tango de vérifier votre identité manuellement.',
    ),
    _Page(
      icon: Icons.send_rounded,
      title: 'Une demande, un ticket',
      body: 'Chaque demande reçoit son propre identifiant, pour que vos documents correspondent à un seul compte.',
    ),
    _Page(
      icon: Icons.forum_rounded,
      title: 'Suivez la réponse',
      body: 'Les réponses du support apparaissent ici, avec une alerte email lorsque vous en avez fourni une.',
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isLast => _index == _pages.length - 1;

  void _next() {
    if (_isLast) {
      widget.onFinished();
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AuroraBackground(
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: widget.onFinished,
                  child: const Text('Passer'),
                ),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _controller,
                  itemCount: _pages.length,
                  onPageChanged: (value) => setState(() => _index = value),
                  itemBuilder: (context, index) =>
                      _PageView(page: _pages[index]),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 26),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < _pages.length; i++)
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 260),
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            height: 8,
                            width: i == _index ? 26 : 8,
                            decoration: BoxDecoration(
                              color: i == _index
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.outlineVariant,
                              borderRadius: BorderRadius.circular(
                                AppRadius.pill,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    GradientButton(
                      onPressed: _next,
                      height: 54,
                      child: Text(_isLast ? 'Commencer' : 'Suivant'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PageView extends StatelessWidget {
  const _PageView({required this.page});

  final _Page page;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            height: 150,
            width: 150,
            decoration: BoxDecoration(
              gradient: AppTheme.heroGradient(theme.brightness),
              borderRadius: BorderRadius.circular(44),
              boxShadow: AppTheme.glow(
                AppColors.violet,
                opacity: 0.45,
                blur: 34,
              ),
            ),
            child: Icon(page.icon, size: 68, color: AppTheme.onHero),
          ),
          const SizedBox(height: 40),
          Text(
            page.title,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            page.body,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

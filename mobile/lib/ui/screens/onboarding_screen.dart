/// First-run onboarding: three concise pages that explain what the app does and
/// what the manual KYC review involves, before the user reaches sign-in.
///
/// Shown once; the choice is persisted so returning users go straight to login.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// One onboarding page.
class _Page {
  const _Page({
    required this.icon,
    required this.title,
    required this.body,
  });

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
      title: 'Manual KYC review',
      body: 'Ask the Tango support team to review your identity verification by hand.',
    ),
    _Page(
      icon: Icons.send_rounded,
      title: 'One request, one ticket',
      body: 'Every request gets its own ticket ID, so your documents map to exactly one account.',
    ),
    _Page(
      icon: Icons.forum_rounded,
      title: 'Follow the answer',
      body: 'Replies from support appear right here, with an email alert when you provided one.',
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
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: widget.onFinished,
                child: const Text('Skip'),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _pages.length,
                onPageChanged: (value) => setState(() => _index = value),
                itemBuilder: (context, index) => _PageView(page: _pages[index]),
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
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _next,
                    child: Text(_isLast ? 'Get started' : 'Next'),
                  ),
                ],
              ),
            ),
          ],
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
              boxShadow: theme.brightness == Brightness.dark
                  ? null
                  : const [
                      BoxShadow(
                        color: Color(0x332F6B5F),
                        blurRadius: 30,
                        offset: Offset(0, 14),
                      ),
                    ],
            ),
            child: Icon(page.icon, size: 68, color: AppTheme.onHero),
          ),
          const SizedBox(height: 40),
          Text(
            page.title,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
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

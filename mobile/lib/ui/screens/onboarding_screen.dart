/// First-run welcome: the premium "Bienvenue sur Tango KYC" introduction.
///
/// A visual refonte only. The screen keeps its single job — telling the root
/// gate that the introduction is done — through [onFinished]; auth, Supabase,
/// Firebase, MVola, tickets and emails are not involved here and are untouched.
///
/// Composition, top to bottom, on the supplied artwork used full-bleed:
///   - the brand lockup, top-left, just under the system status bar;
///   - the headline and the value line, centred above the vertical middle;
///   - the single gradient action, anchored lower with room to breathe.
///
/// The female silhouette and the luminous waves are part of the background PNG
/// itself, so nothing is drawn over them.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/tango_scaffold.dart';

/// The welcome background, used verbatim as a full-screen cover.
const String kWelcomeBackgroundAsset =
    'assets/file_00000000db8c8211a2b37f7c93bcf729.png';

/// The brand lockup PNG, used verbatim: the already-transparent asset, so there
/// is no white square, halo or background plate behind the mark.
const String kWelcomeLogoAsset = 'assets/logo_transparent.png';

/// Width of the logo box, in logical pixels, at the reference canvas.
///
/// Measured from the source: the artwork is square (1254x1254) and the mark's
/// visible field spans the full canvas, so a square box in the 96-116dp band
/// reproduces the reference lockup scale. The value is the ceiling; short
/// canvases shrink it (never grow) so it stays under the status bar.
const double _logoWidth = 72;

/// Height, in logical pixels, of the reference canvas the gaps are tuned for.
const double _referenceHeight = 780;

/// Vertical rhythm, in logical pixels, at the reference height.
const double _logoTopGap = 24;
const double _titleToBodyGap = 26;
const double _bodyToButtonGap = 40;

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onFinished});

  /// Called when the user taps "Commencer"; the caller persists the choice and
  /// routes onward, exactly as before.
  final VoidCallback onFinished;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  @override
  Widget build(BuildContext context) {
    // The background image is dark at the top, so the status bar glyphs are
    // white; the bar itself stays transparent and the artwork shows through.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: TangoKycScaffold(
        safeArea: false,
        body: Stack(
          fit: StackFit.expand,
          children: [
            const _WelcomeBackground(),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final h = constraints.maxHeight;
                  final s = (h / _referenceHeight).clamp(0.72, 1.0);

                  final logoW = (_logoWidth * s).clamp(56.0, 72.0);
                  final side = (24.0 * s).clamp(18.0, 28.0);
                  final bodyMax = (300.0 * s).clamp(240.0, 320.0);
                  final buttonW = (290.0 * s).clamp(220.0, 300.0);
                  final buttonH = (58.0 * s).clamp(50.0, 60.0);

                  return Padding(
                    padding: EdgeInsets.fromLTRB(side, 0, side, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(height: _logoTopGap * s),
                        // Top-left, under the status bar: the reference position.
                        _Logo(width: logoW),
                        // More free space below than above: the headline lands
                        // slightly above the vertical middle, as in the
                        // reference, and the bottom stays airy.
                        const Spacer(flex: 2),
                        _Headline(scale: s, maxWidth: bodyMax),
                        SizedBox(height: _bodyToButtonGap * s),
                        _StartButton(
                          onPressed: widget.onFinished,
                          width: buttonW,
                          height: buttonH,
                        ),
                        // No pagination indicators: the welcome is a single
                        // screen, so the space below the action stays open.
                        const Spacer(flex: 3),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}


/// The full-bleed artwork, drawn exactly as shipped.
class _WelcomeBackground extends StatelessWidget {
  const _WelcomeBackground();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      // Painted under the artwork so a slow decode never flashes white.
      decoration: BoxDecoration(color: Color(0xFF05010D)),
      child: Image(
        image: AssetImage(kWelcomeBackgroundAsset),
        fit: BoxFit.cover,
        alignment: Alignment.center,
        filterQuality: FilterQuality.high,
        gaplessPlayback: true,
      ),
    );
  }
}

/// The brand lockup, drawn straight from the transparent asset.
class _Logo extends StatelessWidget {
  const _Logo({required this.width});

  final double width;

  /// Identifies the logo box for layout assertions in tests.
  static const Key boxKey = Key('welcome-logo-box');

  @override
  Widget build(BuildContext context) {
    // The artwork is 1069x1119 (portrait), so height drives the size and the
    // width is derived, preserving the native ratio exactly.
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        key: boxKey,
        height: width,
        child: Image.asset(
          kWelcomeLogoAsset,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
          gaplessPlayback: true,
        ),
      ),
    );
  }
}

/// "Bienvenue sur" over "Tango KYC", then the value line, left-aligned.
class _Headline extends StatelessWidget {
  const _Headline({required this.scale, required this.maxWidth});

  final double scale;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Bienvenue sur',
              textAlign: TextAlign.left,
              style: TextStyle(
                fontSize: 25 * scale,
                fontWeight: FontWeight.w500,
                height: 1.15,
                color: Colors.white.withValues(alpha: 0.92),
              ),
            ),
            Text(
              'Tango KYC',
              textAlign: TextAlign.left,
              style: TextStyle(
                fontSize: 33 * scale,
                fontWeight: FontWeight.w800,
                height: 1.12,
                letterSpacing: -0.6,
                color: Colors.white,
              ),
            ),
            SizedBox(height: _titleToBodyGap * scale),
            Text(
              'Nous sommes là pour vous aider\n'
              'à résoudre vos problèmes de compte\n'
              'rapidement et en toute sécurité.',
              textAlign: TextAlign.left,
              style: TextStyle(
                fontSize: 15 * scale,
                fontWeight: FontWeight.w400,
                height: 1.5,
                color: const Color(0xFFDCDCE4).withValues(alpha: 0.88),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The single pill action: cyan to violet/magenta, soft shadow, centred label.
class _StartButton extends StatelessWidget {
  const _StartButton({
    required this.onPressed,
    required this.width,
    required this.height,
  });

  final VoidCallback onPressed;
  final double width;
  final double height;

  static const _gradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFFFF2FB0), Color(0xFF8A2BE2), Color(0xFF19C3FF)],
    stops: [0.0, 0.52, 1.0],
  );

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(height / 2);
    return Center(
      child: SizedBox(
        width: width,
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: _gradient,
            borderRadius: radius,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF9C27B0).withValues(alpha: 0.35),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: radius,
            child: InkWell(
              borderRadius: radius,
              onTap: onPressed,
              child: Center(
                child: Text(
                  'Commencer  →',
                  style: TextStyle(
                    fontSize: 17.5 * (height / 58),
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                    letterSpacing: 0.2,
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

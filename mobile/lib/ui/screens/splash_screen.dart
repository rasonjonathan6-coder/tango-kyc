/// Splash: the app's opening frame.
///
/// Presentational only. The root gate (`RootGate` in `main.dart`) decides how
/// long this stays on screen and which route the user lands on next; nothing
/// here reads auth, storage or the network, so the navigation logic is untouched.
///
/// The artwork is used exactly as shipped: the full-bleed background is drawn
/// with [BoxFit.cover] (never stretched, never squashed) and the logo keeps its
/// native aspect ratio at a 130 logical-pixel reference height.
library;

import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/tango_scaffold.dart';

/// The splash background, used verbatim as a full-screen cover.
const String kSplashBackgroundAsset =
    'assets/C1B8CB58-3423-412A-AA98-2BC0EB21595F.png';

/// The brand logo, used verbatim.
const String kSplashLogoAsset = 'assets/logo_transparent.png';

/// Reference height of the logo, in logical pixels, on a phone-sized canvas.
///
/// The source artwork is square (1254x1254), so this sets both dimensions and the
/// ratio is preserved by construction. On shorter canvases the value is scaled
/// down (never up) so the composition cannot overflow.
const double kSplashLogoSize = 130;

/// Canvas height, in logical pixels, at which the reference sizes apply exactly.
///
/// Chosen to sit between the shortest common Android phone (~640dp tall) and the
/// reference artwork's frame, so mid-size and large phones all read at the full
/// reference scale and only genuinely short canvases shrink.
const double _referenceHeight = 760;

/// Vertical rhythm, in logical pixels, tuned for [kSplashLogoSize].
const List<double> _gaps = [26, 10, 18, 30, 16];

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, this.message, this.animate = true});

  /// Optional override for the caption under the loading dots. Null keeps the
  /// default "Chargement..." so every caller gets the finished composition.
  final String? message;

  /// When false the entrance choreography and the pulsing dots are rendered in
  /// their final, static state instead, leaving no pending ticker. Production
  /// always uses the default; widget tests opt out so they settle immediately.
  final bool animate;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with TickerProviderStateMixin {
  /// One-shot entrance: logo, then each line of copy in turn.
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  /// Perpetual, gentle drift for the background artwork.
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 9000),
  );

  /// Steady cycle driving the sequential dot pulse.
  late final AnimationController _dots = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );

  /// Fraction of the entrance at which each element begins its reveal.
  static const double _logoAt = 0.00;
  static const double _titleAt = 0.06;
  static const double _subtitleAt = 0.17;
  static const double _taglineAt = 0.28;
  static const double _dotsAt = 0.39;
  static const double _captionAt = 0.48;

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _entrance.forward();
      _wave.repeat();
      _dots.repeat();
    } else {
      // Land on the finished frame without scheduling a ticker.
      _entrance.value = 1.0;
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    _wave.dispose();
    _dots.dispose();
    super.dispose();
  }

  /// A fade-and-rise reveal that starts at [begin] of the entrance timeline.
  Animation<double> _reveal(double begin) => CurvedAnimation(
        parent: _entrance,
        curve: Interval(begin, (begin + 0.42).clamp(0.0, 1.0), curve: Curves.easeOutCubic),
      );

  Widget _revealChild(Animation<double> t, Widget child, {double rise = 16}) {
    if (!widget.animate) return child;
    return AnimatedBuilder(
      animation: t,
      child: child,
      builder: (context, child) {
        final v = t.value;
        return Opacity(
          opacity: v,
          child: Transform.translate(offset: Offset(0, (1 - v) * rise), child: child),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return TangoKycScaffold(
      safeArea: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _SplashBackground(wave: _wave, animate: widget.animate),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Scale with the available height so nothing is ever clipped.
                // Capped at 1.0: 130dp is the reference *and* the ceiling, so the
                // logo never grows past it on large phones and only shrinks on
                // genuinely short canvases.
                final sq = (constraints.maxHeight / _referenceHeight).clamp(0.62, 1.0);
                final gap = [for (final g in _gaps) g * sq];
                // Explicit breathing space instead of flex: the column lives
                // in a scrollable, so it has no bounded height for a Spacer.
                final topSpace = (constraints.maxHeight * 0.11).clamp(40.0, 150.0);
                final voidSpace = (constraints.maxHeight * 0.15).clamp(36.0, 190.0);

                return SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: constraints.maxHeight),
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24 * sq, vertical: 24 * sq),
                      child: Column(
                        children: [
                          // Brand block in the upper part of the canvas: a little
                          // air above it, a large dark void below it, then the
                          // loading indicator near the bottom.
                          SizedBox(height: topSpace),
                          _revealChild(
                            _reveal(_logoAt),
                            _SplashLogo(size: kSplashLogoSize * sq, animate: widget.animate),
                            rise: 0,
                          ),
                          SizedBox(height: gap[0]),
                          _revealChild(
                            _reveal(_titleAt),
                            _BrandTitle(fontSize: 40 * sq),
                          ),
                          SizedBox(height: gap[1]),
                          _revealChild(
                            _reveal(_subtitleAt),
                            Text(
                              'Votre compte, notre priorité',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 16.5 * sq,
                                fontWeight: FontWeight.w400,
                                height: 1.4,
                                color: Colors.white.withValues(alpha: 0.70),
                              ),
                            ),
                          ),
                          SizedBox(height: gap[2]),
                          _revealChild(
                            _reveal(_taglineAt),
                            Text(
                              'Simple · Rapide · Sécurité',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 14.5 * sq,
                                fontWeight: FontWeight.w500,
                                letterSpacing: 0.2,
                                color: Colors.white.withValues(alpha: 0.85),
                              ),
                            ),
                          ),
                          // The large, dark breathing space of the composition.
                          SizedBox(height: voidSpace),
                          _revealChild(
                            _reveal(_dotsAt),
                            _LoadingDots(progress: _dots, animate: widget.animate),
                            rise: 10,
                          ),
                          SizedBox(height: gap[4]),
                          _revealChild(
                            _reveal(_captionAt),
                            Text(
                              widget.message ?? 'Chargement...',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 13.5 * sq,
                                fontWeight: FontWeight.w400,
                                color: Colors.white.withValues(alpha: 0.60),
                              ),
                            ),
                            rise: 0,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// "Tango KYC": "Tango" in white, "KYC" in the brand neon with a soft bloom.
///
/// A single [Text.rich] so tests searching for the literal "Tango KYC" keep
/// matching, while the two words get distinct styling.
class _BrandTitle extends StatelessWidget {
  const _BrandTitle({required this.fontSize});

  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final kycStyle = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.5,
      foreground: Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFB06BFF), Color(0xFFE458FB), Color(0xFFFF4FD8)],
        ).createShader(Rect.fromLTWH(0, 0, fontSize * 3.2, fontSize)),
      shadows: [
        Shadow(color: AppColors.violet.withValues(alpha: 0.85), blurRadius: fontSize * 0.55),
        Shadow(color: const Color(0xFFE01BD4).withValues(alpha: 0.55), blurRadius: fontSize * 0.95),
      ],
    );

    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: 'Tango ',
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
              color: Colors.white,
            ),
          ),
          TextSpan(text: 'KYC', style: kycStyle),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}

/// The full-bleed artwork.
///
/// Drawn with [BoxFit.cover] so the portrait image fills the canvas edge to edge
/// without distortion; the slow drift is a 2.5% scale so it can never expose an
/// uncovered edge.
class _SplashBackground extends StatelessWidget {
  const _SplashBackground({required this.wave, required this.animate});

  final Animation<double> wave;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    const image = Image(
      image: AssetImage(kSplashBackgroundAsset),
      fit: BoxFit.cover,
      alignment: Alignment.center,
      filterQuality: FilterQuality.high,
      gaplessPlayback: true,
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        // Painted under the artwork so a slow decode never flashes white.
        const ColoredBox(color: AppColors.canvasDark),
        if (!animate)
          image
        else
          AnimatedBuilder(
            animation: wave,
            child: image,
            builder: (context, child) => Transform.scale(
              scale: 1.0 + 0.025 * wave.value,
              child: child,
            ),
          ),
      ],
    );
  }
}

/// The logo, keeping its native ratio, with a soft brand bloom behind it.
class _SplashLogo extends StatelessWidget {
  const _SplashLogo({required this.size, required this.animate});

  final double size;
  final bool animate;

  static const _logo = Image(
    image: AssetImage(kSplashLogoAsset),
    fit: BoxFit.contain,
    filterQuality: FilterQuality.high,
    gaplessPlayback: true,
  );

  @override
  Widget build(BuildContext context) {
    final logo = SizedBox(width: size, height: size, child: _logo);
    if (!animate) return logo;

    // Two blurred, tinted copies of the mark itself: the bloom follows the logo
    // silhouette instead of a rectangle, which is what keeps it premium.
    final violet = _bloom(logo, AppColors.violet, size * 0.10, 0.55);
    final blue = _bloom(logo, AppColors.electric, size * 0.20, 0.30);

    return Stack(
      alignment: Alignment.center,
      children: [blue, violet, logo],
    );
  }

  Widget _bloom(Widget child, Color tint, double sigma, double opacity) {
    return IgnorePointer(
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: Opacity(
          opacity: opacity,
          child: ColorFiltered(
            colorFilter: ColorFilter.mode(tint, BlendMode.srcATop),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// The `● ● ●` indicator: three dots pulsing in sequence, 1-2-3, looping.
class _LoadingDots extends StatelessWidget {
  const _LoadingDots({required this.progress, required this.animate});

  final Animation<double> progress;
  final bool animate;

  static const int _count = 3;
  static const double _dotSize = 7;
  static const double _gap = 9;

  /// Fraction of the cycle each dot is offset from the one before it.
  static const double _stagger = 0.18;

  /// Portion of the cycle a single dot spends brightening; the rest is its rest.
  static const double _pulseWindow = 0.45;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _count; i++) ...[
          if (i > 0) const SizedBox(width: _gap),
          _dot(i),
        ],
      ],
    );
  }

  Widget _dot(int index) {
    if (!animate) return const _DotVisual(intensity: 1);
    return AnimatedBuilder(
      animation: progress,
      builder: (context, _) {
        final phase = (progress.value - index * _stagger) % 1.0;
        final intensity = phase < _pulseWindow
            ? 0.32 + 0.68 * math.sin((phase / _pulseWindow) * math.pi)
            : 0.32;
        return _DotVisual(intensity: intensity);
      },
    );
  }
}

/// A single dot. [intensity] drives both opacity and a slight swell.
class _DotVisual extends StatelessWidget {
  const _DotVisual({required this.intensity});

  final double intensity;

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: 0.82 + 0.18 * intensity,
      child: Container(
        width: _LoadingDots._dotSize,
        height: _LoadingDots._dotSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: intensity),
        ),
      ),
    );
  }
}

/// Atmospheric brand pieces: the animated aurora canvas, the branded logo mark,
/// the gradient primary button and a subtle press-scale wrapper.
///
/// Everything here is presentational only.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The master backdrop: the single source of truth for the app's canvas.
///
/// The composition is transcribed from the reference artwork's welcome screen
/// (the "Bienvenue sur Tango KYC" panel): a near-black navy canvas carrying six
/// luminous pools, each anchored to a *fraction of the viewport* rather than to
/// absolute pixels. Anchoring to the viewport is what makes the very same asset
/// read identically on every route and on every screen size, and it is why the
/// app paints exactly one instance at the root (see `MaterialApp.builder`).
///
/// Pools are fixed: no randomness, no drift. A single one-shot entrance fade
/// replaces the old perpetual animation, so there is no ticker to schedule, no
/// frame-by-frame repaint, and widget tests settle immediately.
class AuroraBackground extends StatefulWidget {
  const AuroraBackground({
    super.key,
    required this.child,
    this.animate = false,
    this.intensity = 1,
  });

  final Widget child;

  /// Retained for call-site compatibility. The backdrop no longer loops; when
  /// true it plays a single short entrance fade, which is the only motion the
  /// master background is allowed.
  final bool animate;

  /// Scales the pool opacity; `0` renders a flat canvas.
  final double intensity;

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    // One-shot: forward() completes, so no ticker is left pending.
    if (widget.animate) _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The app installs the master backdrop at the root; a screen-level instance
    // then just passes through, so nesting stays free and the canvas is painted
    // exactly once per frame.
    if (context.dependOnInheritedWidgetOfExactType<_AuroraScope>() != null) {
      return widget.child;
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (!isDark) {
      // The light scheme stays calm: a plain tinted canvas, no pools.
      return _AuroraScope(
        child: ColoredBox(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: widget.child,
        ),
      );
    }

    return _AuroraScope(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The measured canvas ramp: #01011A at the top easing to #000010.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [AppColors.canvasDark, AppColors.canvasDeep],
              ),
            ),
          ),
          RepaintBoundary(
            child: widget.animate
                ? FadeTransition(
                    opacity: CurvedAnimation(
                      parent: _controller,
                      curve: Curves.easeOut,
                    ),
                    child: CustomPaint(
                      painter: MasterBackdropPainter(
                        intensity: widget.intensity,
                      ),
                    ),
                  )
                : CustomPaint(
                    painter: MasterBackdropPainter(
                      intensity: widget.intensity,
                    ),
                  ),
          ),
          widget.child,
        ],
      ),
    );
  }
}

/// Marker so a nested [AuroraBackground] knows the backdrop is already painted.
class _AuroraScope extends InheritedWidget {
  const _AuroraScope({required super.child});

  @override
  bool updateShouldNotify(_AuroraScope oldWidget) => false;
}

/// One luminous pool of the master backdrop.
class BackdropPool {
  const BackdropPool(this.x, this.y, this.radius, this.color, this.alpha);

  /// Centre, as a fraction of the viewport.
  final double x;
  final double y;

  /// Radius, as a fraction of the viewport width.
  final double radius;
  final Color color;
  final double alpha;
}

/// Paints the master backdrop, transcribed from the reference artwork.
///
/// The pools below are the ones measured off the reference screens. Their
/// fractions and colours are the asset: change them here and every route moves
/// together.
class MasterBackdropPainter extends CustomPainter {
  const MasterBackdropPainter({required this.intensity});

  final double intensity;

  /// Positions are fractions of the viewport; radii are fractions of its width.
  /// Colours are the measured pool colours; the alphas tune them down so text
  /// keeps full contrast on top.
  ///
  /// Measured against the reference, the canvas reads *cool*: over the dark
  /// background the blue channel dominates and red is only a small fraction of
  /// it (R/B ≈ 0.09, G/B ≈ 0.13). The magenta pools are therefore small, tight
  /// accents on top of a broad blue wash — not the diffuse magenta field a
  /// larger radius would produce.
  static const List<BackdropPool> pools = [
    // Broad, low cool wash: this is what sets the canvas to a blue-leaning
    // near-black rather than leaving the magenta pools to tint the whole page.
    BackdropPool(0.62, 0.34, 1.05, AppColors.poolCanvasBlue, 0.20),
    // Top-left magenta bloom, kept in the top band so it cannot tint content.
    BackdropPool(0.07, 0.11, 0.11, AppColors.poolMagentaTop, 0.26),
    // Top-right teal: the green channel that keeps the canvas cool.
    BackdropPool(0.97, 0.06, 0.26, AppColors.poolTeal, 0.24),
    // Mid-right deep blue.
    BackdropPool(1.00, 0.45, 0.26, AppColors.poolBlue, 0.30),
    // Lower-left magenta, held in the bottom band.
    BackdropPool(0.07, 0.93, 0.12, AppColors.poolMagentaLow, 0.28),
    // Lower-centre violet.
    BackdropPool(0.50, 0.94, 0.20, AppColors.poolVioletLow, 0.26),
    // Lower-right indigo.
    BackdropPool(0.96, 0.95, 0.18, AppColors.poolIndigo, 0.34),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (intensity <= 0) return;
    final w = size.width;

    for (final pool in pools) {
      final center = Offset(w * pool.x, size.height * pool.y);
      final radius = w * pool.radius;
      final alpha = (pool.alpha * intensity).clamp(0.0, 1.0);

      // Two additive passes per pool: a wide soft halo, then a tight bright
      // core. Additive light means overlaps brighten and the canvas stays black
      // away from the pools, which is what keeps the reference's glow
      // concentrated instead of washing the whole screen violet.
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = RadialGradient(
            colors: [
              pool.color.withValues(alpha: alpha * 0.70),
              pool.color.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
      // The broad canvas wash relies on the halo alone: a bright core on a
      // pool that wide would read as a hotspot in the middle of the page.
      if (pool.radius > 0.5) continue;
      final core = radius * 0.50;
      final coreAlpha = (alpha * 1.25).clamp(0.0, 1.0);
      canvas.drawCircle(
        center,
        core,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = RadialGradient(
            colors: [
              pool.color.withValues(alpha: coreAlpha),
              pool.color.withValues(alpha: coreAlpha * 0.5),
              pool.color.withValues(alpha: 0),
            ],
            stops: const [0.0, 0.45, 1.0],
          ).createShader(Rect.fromCircle(center: center, radius: core)),
      );
    }

    // Two barely-there light streaks, purely for the glass texture of the
    // reference. Drawn last so they sit over the pools.
    final streak = Paint()
      ..strokeWidth = 1.1
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: 0),
          Colors.white.withValues(alpha: 0.04 * intensity),
          Colors.white.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawLine(
      Offset(-w * 0.1, size.height * 0.30),
      Offset(w * 1.1, size.height * 0.05),
      streak,
    );
    canvas.drawLine(
      Offset(-w * 0.1, size.height * 0.72),
      Offset(w * 1.1, size.height * 0.95),
      streak,
    );
  }

  @override
  bool shouldRepaint(MasterBackdropPainter old) => old.intensity != intensity;
}

/// The brand mark used on auth, splash and onboarding surfaces.
///
/// A rounded gradient tile carrying the shield glyph, with a soft bloom in dark
/// mode instead of a drop shadow.
class LogoMark extends StatelessWidget {
  const LogoMark({
    super.key,
    this.size = 76,
    this.iconSize,
    this.animate = true,
    this.icon = Icons.verified_user_rounded,
  });

  final double size;
  final double? iconSize;
  final bool animate;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mark = Container(
      height: size,
      width: size,
      decoration: BoxDecoration(
        gradient: AppTheme.brandGradient,
        borderRadius: BorderRadius.circular(size * 0.30),
        boxShadow: AppTheme.glow(
          AppColors.violet,
          opacity: isDark ? 0.55 : 0.35,
          blur: size * 0.45,
        ),
      ),
      child: Icon(icon, size: iconSize ?? size * 0.5, color: Colors.white),
    );

    if (!animate) return mark;

    // A gentle breathing pulse, so the mark feels alive without being noisy.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 1400),
      curve: Curves.easeInOut,
      child: mark,
      builder: (context, value, child) {
        final pulse = 1 + 0.03 * math.sin(value * math.pi * 2);
        return Transform.scale(scale: pulse, child: child);
      },
    );
  }
}

/// Primary action: the brand gradient, a violet bloom and a press-scale feel.
///
/// Used instead of a plain [FilledButton] wherever the action is *the* thing the
/// screen is asking for (sign in, send request, pay).
class GradientButton extends StatefulWidget {
  const GradientButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.height = 56,
    this.radius,
    this.busy = false,
    this.gradient,
    this.textStyle,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final IconData? icon;
  final double height;

  /// Corner radius. Defaults to the shared medium radius.
  final double? radius;
  final bool busy;

  /// Overrides the fill; defaults to [AppTheme.brandGradient].
  final Gradient? gradient;

  /// Overrides the label style, so a screen can size its primary action.
  final TextStyle? textStyle;

  @override
  State<GradientButton> createState() => _GradientButtonState();
}

class _GradientButtonState extends State<GradientButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final enabled = widget.onPressed != null && !widget.busy;
    final radius = BorderRadius.circular(widget.radius ?? AppRadius.md);

    return AnimatedScale(
      scale: _pressed ? 0.975 : 1,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOut,
      child: Opacity(
        opacity: enabled ? 1 : 0.55,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: widget.gradient ?? AppTheme.brandGradient,
            borderRadius: radius,
            boxShadow: enabled
                ? AppTheme.glow(
                    AppColors.violet,
                    opacity: isDark ? 0.45 : 0.30,
                    blur: 22,
                  )
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: radius,
            child: InkWell(
              borderRadius: radius,
              onTap: enabled ? widget.onPressed : null,
              onTapDown: enabled
                  ? (_) => setState(() => _pressed = true)
                  : null,
              onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
              onTapCancel: enabled
                  ? () => setState(() => _pressed = false)
                  : null,
              child: SizedBox(
                height: widget.height,
                child: Center(
                  child: widget.busy
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            valueColor: AlwaysStoppedAnimation(Colors.white),
                          ),
                        )
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.icon != null) ...[
                              Icon(widget.icon, size: 20, color: Colors.white),
                              const SizedBox(width: 10),
                            ],
                            Flexible(
                              child: DefaultTextStyle(
                                style:
                                    widget.textStyle ??
                                    const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.2,
                                    ),
                                textAlign: TextAlign.center,
                                child: widget.child,
                              ),
                            ),
                          ],
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

/// Wraps content so it fades and rises into place, with an optional delay.
///
/// A lightweight, dependency-free entrance used to stagger a screen's sections.
class Reveal extends StatelessWidget {
  const Reveal({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 420),
  });

  final Widget child;
  final Duration delay;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration + delay,
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, value, child) {
        final clamped = value == 0 ? 0.0 : value;
        return Opacity(
          opacity: clamped,
          child: Transform.translate(
            offset: Offset(0, 16 * (1 - clamped)),
            child: child,
          ),
        );
      },
    );
  }
}

/// A glassy surface used for grouped settings and detail blocks.
///
/// Slightly translucent in dark mode so the aurora shows through, with a faint
/// violet hairline framing it.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.md),
    this.margin = EdgeInsets.zero,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;

    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: isDark ? AppColors.glassFill.withValues(alpha: 0.12) : Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: isDark
              ? scheme.outlineVariant.withValues(alpha: 0.65)
              : scheme.outlineVariant,
        ),
      ),
      child: child,
    );
  }
}

/// Atmospheric brand pieces: the animated aurora canvas, the branded logo mark,
/// the gradient primary button and a subtle press-scale wrapper.
///
/// Everything here is presentational only.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The signature backdrop from the product artwork: a near-black navy canvas lit
/// by three slowly drifting violet, magenta and indigo auras.
///
/// The animation is a single long-period [AnimationController] driving a
/// [CustomPainter]; nothing is rebuilt per frame beyond the paint itself, so it
/// stays smooth on low-end devices. The colours are very low alpha so content
/// keeps full contrast.
class AuroraBackground extends StatefulWidget {
  const AuroraBackground({
    super.key,
    required this.child,
    this.animate = false,
    this.intensity = 1,
  });

  final Widget child;

  /// Whether the auras drift. Off by default so a screen never leaves a ticker
  /// pending under a widget test; the app's root backdrop opts in.
  final bool animate;

  /// Scales the aura opacity; `0` renders a flat canvas.
  final double intensity;

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 22),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The app installs one aurora at the root (see `MaterialApp.builder`); a
    // screen-level instance then just passes through, so nesting stays free and
    // no aura is painted twice.
    if (context.dependOnInheritedWidgetOfExactType<_AuroraScope>() != null) {
      return widget.child;
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (!isDark) {
      // The light scheme stays calm: a plain tinted canvas, no auras.
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
          ColoredBox(color: Theme.of(context).scaffoldBackgroundColor),
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) => CustomPaint(
                painter: _AuroraPainter(
                  t: widget.animate ? _controller.value : 0,
                  intensity: widget.intensity,
                ),
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

class _AuroraPainter extends CustomPainter {
  _AuroraPainter({required this.t, required this.intensity});

  final double t;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    if (intensity <= 0) return;
    final angle = t * 2 * math.pi;

    void aurora(Offset center, double radius, Color color, double alpha) {
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [color.withValues(alpha: alpha * intensity), color.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawCircle(center, radius, paint);
    }

    // Three auras, each on its own elliptical drift, matching the artwork's
    // violet top-right, magenta bottom-left and indigo bottom-right corners.
    aurora(
      Offset(
        size.width * (0.82 + 0.10 * math.cos(angle)),
        size.height * (0.10 + 0.06 * math.sin(angle)),
      ),
      size.width * 1.05,
      AppColors.violetBright,
      0.30,
    );
    aurora(
      Offset(
        size.width * (0.08 + 0.08 * math.sin(angle + 1.2)),
        size.height * (0.94 + 0.05 * math.cos(angle + 0.6)),
      ),
      size.width * 0.95,
      AppColors.magenta,
      0.24,
    );
    aurora(
      Offset(
        size.width * (0.92 + 0.07 * math.cos(angle + 2.4)),
        size.height * (0.86 + 0.06 * math.sin(angle + 1.8)),
      ),
      size.width * 0.80,
      AppColors.indigo,
      0.20,
    );
  }

  @override
  bool shouldRepaint(_AuroraPainter old) =>
      old.t != t || old.intensity != intensity;
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
      child: Icon(
        icon,
        size: iconSize ?? size * 0.5,
        color: Colors.white,
      ),
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
                ? AppTheme.glow(AppColors.violet,
                    opacity: isDark ? 0.45 : 0.30, blur: 22)
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: radius,
            child: InkWell(
              borderRadius: radius,
              onTap: enabled ? widget.onPressed : null,
              onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
              onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
              onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
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
                            DefaultTextStyle(
                              style: widget.textStyle ??
                                  const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.2,
                                  ),
                              child: widget.child,
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
          child: Transform.translate(offset: Offset(0, 16 * (1 - clamped)), child: child),
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
        color: isDark
            ? Colors.white.withValues(alpha: 0.035)
            : Colors.white,
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

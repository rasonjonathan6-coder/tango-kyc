/// Premium pieces used by the authentication surfaces.
///
/// A single visual language: a near-black canvas lit by soft magenta/violet/
/// blue halos, glassy fields framed by a hairline neon gradient, a bright
/// rose→violet→electric primary action and quiet glass cards for the secondary
/// entry points.
///
/// Everything here is presentational. No screen reaches the network through this
/// file, and none of it owns authentication state — the login screen keeps its
/// own controllers, validators and navigation.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'aurora.dart';

/// The richer halo composition behind the auth screens.
///
/// Static by design: the app-level [AuroraBackground] already drifts, so this
/// layer only adds the extra magenta/violet/rose/cyan pools the reference
/// artwork shows. Static also means widget tests settle instantly.
class AuthHalo extends StatelessWidget {
  const AuthHalo({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).brightness != Brightness.dark) return child;
    return Stack(
      fit: StackFit.expand,
      children: [
        const RepaintBoundary(child: CustomPaint(painter: _HaloPainter())),
        child,
      ],
    );
  }
}

class _HaloPainter extends CustomPainter {
  const _HaloPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    void halo(Offset center, double radius, Color color, double alpha) {
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [color.withValues(alpha: alpha), color.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawCircle(center, radius, paint);
    }

    // Five pools, low alpha so text keeps full contrast.
    halo(Offset(w * 0.02, h * 0.06), w * 0.80, AppColors.magenta, 0.13);
    halo(Offset(w * 0.50, h * 0.01), w * 0.95, AppColors.violet, 0.15);
    halo(Offset(w * 1.06, h * 0.28), w * 0.88, AppColors.rose, 0.14);
    halo(Offset(w * 0.96, h * 0.93), w * 0.92, AppColors.electric, 0.13);
    halo(Offset(w * 0.04, h * 0.90), w * 0.82, AppColors.violetBright, 0.11);

    // Two barely-there light streaks, purely for texture.
    final streak = Paint()
      ..strokeWidth = 1.1
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: 0),
          Colors.white.withValues(alpha: 0.045),
          Colors.white.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    canvas.drawLine(Offset(-w * 0.1, h * 0.30), Offset(w * 1.1, h * 0.05), streak);
    canvas.drawLine(Offset(-w * 0.1, h * 0.72), Offset(w * 1.1, h * 0.95), streak);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// The brand lockup: mark, wordmark and a small gradient "Live" badge.
class BrandLockup extends StatelessWidget {
  const BrandLockup({super.key, this.markSize = 36});

  final double markSize;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        LogoMark(
          size: markSize,
          iconSize: markSize * 0.55,
          animate: false,
          icon: Icons.verified_user_rounded,
        ),
        const SizedBox(width: 11),
        const Text(
          'Tango',
          style: TextStyle(
            color: Colors.white,
            fontSize: 21,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(width: 7),
        const _LiveBadge(),
      ],
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        gradient: AppTheme.actionGradient,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        boxShadow: AppTheme.glow(AppColors.violet, opacity: 0.35, blur: 12),
      ),
      child: const Text(
        'Live',
        style: TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// A glass form field framed by a hairline neon gradient.
///
/// Keeps [TextFormField] semantics — validation, autofill, obscure toggling and
/// the error text — so the screens above it are unchanged functionally. Only the
/// presentation differs: a gradient frame, a large leading icon, a lavender
/// label and a focus bloom.
class NeonField extends StatefulWidget {
  const NeonField({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.icon = Icons.alternate_email_rounded,
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.obscureText = false,
    this.enabled = true,
    this.validator,
    this.onSubmitted,
    this.suffix,
    this.radius = 30,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final IconData icon;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final bool obscureText;
  final bool enabled;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onSubmitted;
  final Widget? suffix;
  final double radius;

  @override
  State<NeonField> createState() => _NeonFieldState();
}

class _NeonFieldState extends State<NeonField> {
  final FocusNode _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (mounted) setState(() => _focused = _focus.hasFocus);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final radius = BorderRadius.circular(widget.radius);

    final glass = isDark
        ? const Color(0xFF1E143C).withValues(alpha: 0.70)
        : Colors.white;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
          style: TextStyle(
            color: isDark ? const Color(0xFFCDBDF0) : theme.colorScheme.onSurfaceVariant,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(height: 6),
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            gradient: isDark ? AppTheme.neonHairline : null,
            color: isDark ? null : theme.colorScheme.outlineVariant,
            borderRadius: radius,
            boxShadow: _focused && isDark
                ? AppTheme.glow(AppColors.violetBright, opacity: 0.30, blur: 22)
                : null,
          ),
          padding: EdgeInsets.all(isDark ? 1.6 : 1),
          child: Container(
            decoration: BoxDecoration(
              color: glass,
              borderRadius: BorderRadius.circular(widget.radius - 2),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(
                  widget.icon,
                  size: 24,
                  color: isDark
                      ? AppColors.violetBright.withValues(alpha: 0.95)
                      : theme.colorScheme.primary,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: TextFormField(
                    controller: widget.controller,
                    focusNode: _focus,
                    enabled: widget.enabled,
                    keyboardType: widget.keyboardType,
                    textInputAction: widget.textInputAction,
                    autofillHints: widget.autofillHints,
                    obscureText: widget.obscureText,
                    onFieldSubmitted: widget.onSubmitted,
                    validator: widget.validator,
                    style: TextStyle(
                      color: isDark ? Colors.white : theme.colorScheme.onSurface,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: InputDecoration(
                      hintText: widget.hint,
                      hintStyle: TextStyle(
                        color: isDark
                            ? const Color(0xFF9A88C4).withValues(alpha: 0.85)
                            : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                        fontSize: 15.5,
                        fontWeight: FontWeight.w400,
                      ),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 18),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                      errorStyle: TextStyle(
                        color: isDark ? const Color(0xFFFF8FA8) : theme.colorScheme.error,
                        fontSize: 12.5,
                        height: 1.25,
                      ),
                      errorMaxLines: 2,
                    ),
                  ),
                ),
                if (widget.suffix != null) ...[
                  const SizedBox(width: 4),
                  widget.suffix!,
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A tappable glass card, used for Google sign-in and the secondary entries.
///
/// [onTap] is always the real handler: this widget never simulates an action.
class GlassActionCard extends StatefulWidget {
  const GlassActionCard({
    super.key,
    required this.onTap,
    required this.child,
    this.enabled = true,
    this.radius = 28,
    this.height,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
  });

  final VoidCallback? onTap;
  final Widget child;
  final bool enabled;
  final double radius;
  final double? height;
  final EdgeInsetsGeometry padding;

  @override
  State<GlassActionCard> createState() => _GlassActionCardState();
}

class _GlassActionCardState extends State<GlassActionCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(widget.radius);
    final active = widget.enabled && widget.onTap != null;

    return AnimatedScale(
      scale: _pressed ? 0.98 : 1,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: Opacity(
        opacity: active ? 1 : 0.5,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(
              color: isDark
                  ? AppColors.violet.withValues(alpha: 0.45)
                  : theme.colorScheme.outlineVariant,
            ),
            color: isDark
                ? Colors.white.withValues(alpha: 0.055)
                : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: radius,
            child: InkWell(
              borderRadius: radius,
              onTap: active ? widget.onTap : null,
              onTapDown: active ? (_) => setState(() => _pressed = true) : null,
              onTapUp: active ? (_) => setState(() => _pressed = false) : null,
              onTapCancel: active ? () => setState(() => _pressed = false) : null,
              child: SizedBox(
                height: widget.height,
                child: Padding(padding: widget.padding, child: widget.child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Google mark, drawn as four arcs plus the crossbar.
///
/// Painted rather than bundled: the project ships no Google asset, and pulling
/// one from the network at runtime would be both fragile and off-brand. The
/// geometry is the public four-colour ring.
class GoogleGlyph extends StatelessWidget {
  const GoogleGlyph({super.key, this.size = 24});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _GooglePainter()),
    );
  }
}

class _GooglePainter extends CustomPainter {
  static const Color _blue = Color(0xFF4285F4);
  static const Color _green = Color(0xFF34A853);
  static const Color _yellow = Color(0xFFFBBC05);
  static const Color _red = Color(0xFFEA4335);

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.235;
    final rect = Rect.fromLTWH(
      stroke / 2,
      stroke / 2,
      size.width - stroke,
      size.height - stroke,
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;

    // Angles grow clockwise from 3 o'clock in Flutter's coordinate space.
    void arc(double startDeg, double sweepDeg, Color color) {
      canvas.drawArc(
        rect,
        startDeg * math.pi / 180,
        sweepDeg * math.pi / 180,
        false,
        paint..color = color,
      );
    }

    arc(-45, 90, _blue); // right
    arc(45, 90, _green); // bottom
    arc(135, 90, _yellow); // left
    arc(225, 90, _red); // top

    // The blue crossbar entering from the right, at the vertical centre.
    final bar = Paint()..color = _blue;
    canvas.drawRect(
      Rect.fromLTWH(
        size.width * 0.50,
        size.height / 2 - stroke / 2,
        size.width * 0.50 - stroke / 2,
        stroke,
      ),
      bar,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// The closing tagline: a rose heart and a quiet line of copy.
class AuthFooter extends StatelessWidget {
  const AuthFooter({super.key});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.favorite_rounded, size: 13, color: AppColors.rose.withValues(alpha: 0.9)),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            'Tango · Plus qu’une app, une communauté',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: muted.withValues(alpha: 0.75),
              fontSize: 12,
              letterSpacing: 0.1,
            ),
          ),
        ),
      ],
    );
  }
}

/// The elegant "ou" rule between the primary action and Google.
class OrDivider extends StatelessWidget {
  const OrDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final line = Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.28);
    return Row(
      children: [
        Expanded(child: Divider(color: line, height: 1)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text(
            'ou',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
        ),
        Expanded(child: Divider(color: line, height: 1)),
      ],
    );
  }
}

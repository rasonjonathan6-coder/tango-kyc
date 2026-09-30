/// Premium pieces used by the authentication surfaces.
///
/// A single visual language: glassy fields framed by a hairline neon gradient, a
/// bright rose→violet→electric primary action and quiet glass cards for the
/// secondary entry points.
///
/// The backdrop is NOT defined here: the whole app shares the one master
/// backdrop painted at the root (see [AuroraBackground] in `aurora.dart`).
///
/// Everything here is presentational. No screen reaches the network through this
/// file, and none of it owns authentication state — the login screen keeps its
/// own controllers, validators and navigation.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'aurora.dart';
import 'brand_mark.dart';

/// The dedicated art background for the three authentication screens (Login,
/// Register, Forgot Password).
///
/// The artwork already bakes the whole composition — deep navy left, magenta /
/// violet / cyan neon on the right — so it is used verbatim as a full-bleed
/// cover, with the content sitting over it. Unlike the shared app canvas, the
/// artwork stays dark in both brightnesses, so this subtree pins
/// [ThemeMode.dark]: the fields, headings and links keep the neon treatment the
/// mockup calls for instead of flipping to a light theme over a dark picture.
class AuthBackground extends StatelessWidget {
  const AuthBackground({super.key, required this.child});

  /// Cover artwork for the auth surfaces. Declared in the pubspec (`assets/`).
  static const String asset =
      'assets/file_000000001fc482078d578b26c2203e44.png';

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Pin only the theme; inherit the ambient locale/direction/medias. The dark
    // scheme is used as-is so the whole subtree (fields, headings, links)
    // renders the neon treatment over the artwork.
    final base = Theme.of(context);
    final pinned = base.brightness == Brightness.dark ? base : AppTheme.dark();

    return Theme(
      data: pinned,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: Image.asset(
              asset,
              fit: BoxFit.cover,
              alignment: Alignment.center,
              // Keep the neon/right side readable on very tall canvases.
              filterQuality: FilterQuality.medium,
            ),
          ),
          // A left-weighted scrim. The copy lives over the artwork's left/centre,
          // where the neon is brightest; this keeps the magenta and white text
          // legible there while leaving the far-right silhouette crisp.
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  stops: [0.0, 0.60, 1.0],
                  colors: [
                    Color(0x9E000000),
                    Color(0x9E000000),
                    Color(0x00000000),
                  ],
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
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
        // The real brand mark, so the auth screens and the home header show the
        // same lockup instead of a gradient plate with a generic shield icon.
        BrandMark(height: markSize),
        const SizedBox(width: 11),
        Text(
          'Tango',
          style: TextStyle(
            color: context.tokens.textPrimary,
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
            color: isDark
                ? const Color(0xFFCDBDF0)
                : theme.colorScheme.onSurfaceVariant,
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
                      color: isDark
                          ? Colors.white
                          : theme.colorScheme.onSurface,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: InputDecoration(
                      hintText: widget.hint,
                      hintStyle: TextStyle(
                        color: isDark
                            ? const Color(0xFF9A88C4).withValues(alpha: 0.85)
                            : theme.colorScheme.onSurfaceVariant.withValues(
                                alpha: 0.8,
                              ),
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
                        color: isDark
                            ? const Color(0xFFFF8FA8)
                            : theme.colorScheme.error,
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
                : theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.4,
                  ),
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: radius,
            child: InkWell(
              borderRadius: radius,
              onTap: active ? widget.onTap : null,
              onTapDown: active ? (_) => setState(() => _pressed = true) : null,
              onTapUp: active ? (_) => setState(() => _pressed = false) : null,
              onTapCancel: active
                  ? () => setState(() => _pressed = false)
                  : null,
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
        Icon(
          Icons.favorite_rounded,
          size: 13,
          color: AppColors.rose.withValues(alpha: 0.9),
        ),
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
    final line = Theme.of(context).colorScheme.onSurfaceVariant
        .withValues(alpha: 0.28);
    return Row(
      children: [
        Expanded(child: Divider(color: line, height: 1)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text(
            'ou',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant
                  .withValues(alpha: 0.85),
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

/// One run of a heading: plain white, or painted with the brand ramp.
class HeadingSegment {
  const HeadingSegment(this.text, {this.gradient = false});

  final String text;
  final bool gradient;
}

/// The large gradient heading shared by every auth surface.
///
/// A [Column] of [Wrap] rows, each row a run of segments. This is the same
/// technique the login title already used — a [ShaderMask] around the single
/// gradient fragment — so the white runs stay white while the accent carries the
/// magenta→violet→electric ramp, and a long word still wraps instead of
/// overflowing.
class AuthHeading extends StatelessWidget {
  const AuthHeading({
    super.key,
    required this.lines,
    this.size,
    this.align = TextAlign.center,
  });

  final List<List<HeadingSegment>> lines;
  final double? size;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final resolved = size ?? (width * 0.105).clamp(28.0, 42.0);
    final style = TextStyle(
      fontSize: resolved,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.8,
      height: 1.14,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (final line in lines)
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: resolved * 0.24,
            children: [
              for (final seg in line)
                seg.gradient
                    ? ShaderMask(
                        shaderCallback: (bounds) =>
                            AppTheme.brandGradient.createShader(bounds),
                        child: Text(
                          seg.text,
                          textAlign: align,
                          style: style.copyWith(color: Colors.white),
                        ),
                      )
                    : Text(
                        seg.text,
                        textAlign: align,
                        style: style.copyWith(
                          color: context.tokens.textPrimary,
                        ),
                      ),
            ],
          ),
      ],
    );
  }
}

/// Centred content column for the auth pages.
///
/// Keeps the reference reading order — lockup, heading, copy, fields, action —
/// inside a scroll view so a short screen scrolls rather than overflowing.
class AuthScreenLayout extends StatelessWidget {
  const AuthScreenLayout({
    super.key,
    required this.children,
    this.maxWidth = 440,
    this.padding = const EdgeInsets.fromLTRB(22, 8, 22, 20),
  });

  final List<Widget> children;
  final double maxWidth;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: padding,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}

/// The centred explanatory line under an auth heading.
///
/// A descendant widget on purpose: it reads [AppTokensX.tokens] below
/// [AuthBackground]'s pinned dark [Theme], so the copy keeps its dark-mode
/// colour even when the app itself is in light mode.
class AuthSubtitle extends StatelessWidget {
  const AuthSubtitle(this.text, {super.key, this.fontSize = 17});

  final String text;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: context.tokens.textSecondary.withValues(alpha: 0.92),
        fontSize: fontSize,
        height: 1.4,
      ),
    );
  }
}

/// A quiet centred link, optionally neon-tinted and with a trailing chevron.
class AuthTextLink extends StatelessWidget {
  const AuthTextLink({
    super.key,
    required this.label,
    required this.onPressed,
    this.color,
    this.chevron = false,
    this.fontSize = 15,
  });

  final String label;
  final VoidCallback? onPressed;
  final Color? color;
  final bool chevron;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        minimumSize: const Size(0, 40),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: color ?? Colors.white,
        textStyle: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(child: Text(label, textAlign: TextAlign.center)),
          if (chevron) ...[
            const SizedBox(width: 3),
            Icon(
              Icons.arrow_forward_ios_rounded,
              size: fontSize - 3,
              color: color ?? Colors.white,
            ),
          ],
        ],
      ),
    );
  }
}

/// A glass tile behind one OTP digit.
///
/// Presentation only: the single real [TextField] lives in the parent and is
/// layered over a row of these, so no code-input behaviour is added here.
class GhostTile extends StatelessWidget {
  const GhostTile({
    super.key,
    required this.filled,
    this.char = '',
    this.size = 38,
  });

  final bool filled;
  final String char;
  final double size;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: size,
      height: size + 14,
      decoration: BoxDecoration(
        gradient: AppTheme.neonHairline,
        borderRadius: BorderRadius.circular(15),
        boxShadow: filled
            ? AppTheme.glow(AppColors.cyan, opacity: 0.26, blur: 14)
            : null,
      ),
      padding: const EdgeInsets.all(1.6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF1E143C).withValues(alpha: 0.74),
          borderRadius: BorderRadius.circular(13.4),
        ),
        child: Center(
          child: Text(
            char,
            style: TextStyle(
              color: Colors.white,
              fontSize: size * 0.62,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

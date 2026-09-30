/// Centralised design system for Tango KYC Verification.
///
/// One dark, neon-on-black identity drives the whole app: a near-black navy
/// canvas, soft violet/magenta auras and a single electric gradient accent. Both
/// schemes derive from the same brand ramp so screens stay declarative and the
/// entire product moves together.
library;

import 'package:flutter/material.dart';

/// Spacing scale, so vertical rhythm stays even across screens.
abstract final class AppSpacing {
  static const double xs = 6;
  static const double sm = 10;
  static const double md = 16;
  static const double lg = 22;
  static const double xl = 30;

  /// Standard page padding: comfortable on small Android screens.
  static const EdgeInsets page = EdgeInsets.fromLTRB(18, 10, 18, 34);

  /// Widest the Home content column is allowed to grow.
  ///
  /// Decisions are driven by the space actually available, never by a device
  /// class: past this width the column is centred instead of stretched, so a
  /// large window keeps a readable line length rather than a sparse one.
  static const double maxContentWidth = 560;

  /// Horizontal page padding that adapts to the real width: narrower gutters on
  /// a small canvas, roomier ones once there is space to spare.
  static EdgeInsets pageFor(double width) =>
      EdgeInsets.fromLTRB(width < 360 ? 14 : 18, 10, width < 360 ? 14 : 18, 34);
}

/// Corner radii, from chips up to hero surfaces.
abstract final class AppRadius {
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 26;
  static const double pill = 999;
}

/// The brand palette, measured off the reference artwork.
///
/// The canvas is a near-black navy rather than pure black, so the luminous
/// pools have something to bloom against. [canvasDark] and [canvasDeep] are the
/// measured top and bottom of the backdrop's vertical ramp.
abstract final class AppColors {
  static const Color canvasDark = Color(0xFF01011A);
  static const Color canvasDeep = Color(0xFF000010);
  static const Color surfaceDark = Color(0xFF130B23);
  static const Color surfaceHigh = Color(0xFF1B1130);

  /// Electric violet: the primary accent and the top of the gradient.
  static const Color violet = Color(0xFF921BF9);
  static const Color violetBright = Color(0xFFC31BFB);

  /// Magenta: the bottom of the gradient and the counter-aura.
  static const Color magenta = Color(0xFFE01BD4);

  /// Neon rose: the warm end of the primary action gradient.
  static const Color rose = Color(0xFFFF0A8A);

  /// Electric blue: the cool end of the primary action gradient.
  static const Color electric = Color(0xFF168CFF);

  /// Cyan: the coolest halo in the backdrop.
  static const Color cyan = Color(0xFF16E0FF);

  /// Indigo used for the cool corner of the background.
  static const Color indigo = Color(0xFF3B2BFF);

  // The measured backdrop pool colours. Kept here, next to the palette, so
  // the backdrop painter and any future preview share one definition.
  static const Color poolMagentaTop = Color(0xFFF902C5);
  static const Color poolMagentaLow = Color(0xFFF302C8);
  static const Color poolVioletLow = Color(0xFF5F0EFD);
  static const Color poolBlue = Color(0xFF1A43A8);
  static const Color poolDeepBlue = Color(0xFF090D6D);
  static const Color poolIndigo = Color(0xFF3E15D9);

  /// The cool teal-green pools. Measured off the reference, the canvas is not
  /// purely magenta/violet: the mid and upper right carry a teal glow whose
  /// green channel is what keeps the composition from reading as a warm bruise.
  static const Color poolTeal = Color(0xFF0FA3B1);
  static const Color poolTealDeep = Color(0xFF0B6E99);

  /// The broad canvas wash. Deliberately a pure blue, so the page floor is cool
  /// and the tight magenta accents above it never tint the whole screen.
  static const Color poolCanvasBlue = Color(0xFF1326C8);

  /// The dark-mode glass fill for cards and grouped surfaces.
  ///
  /// Measured off the reference: a card over the canvas reads as a *blue*
  /// translucent panel (roughly `rgb(0, 8, 44)`), not a neutral grey one. A
  /// white wash would desaturate the composition and push the red channel up,
  /// so the glass carries its own blue instead.
  static const Color glassFill = Color(0xFF0050D7);

  static const Color canvasLight = Color(0xFFF7F4FD);
  static const Color surfaceLight = Color(0xFFFFFFFF);

  /// Text colours per brightness. Centralised so a screen never hardcodes a
  /// white that only reads on the dark canvas: the light mode swaps in near-black
  /// ink instead of leaving white-on-white.
  static const Color textPrimaryDark = Color(0xFFF5F7FF);
  static const Color textSecondaryDark = Color(0xFFB8C5E8);
  static const Color textPrimaryLight = Color(0xFF160B24);
  static const Color textSecondaryLight = Color(0xFF4A3D63);
}

/// Theme-aware colour tokens, resolved from the ambient [Theme].
///
/// Screens read `context.tokens.textSecondary` instead of hardcoding a colour, so
/// switching Android between dark and light repaints every surface consistently.
extension AppTokensX on BuildContext {
  AppTokens get tokens => Theme.of(this).brightness == Brightness.dark
      ? const AppTokens.dark()
      : const AppTokens.light();
}

class AppTokens {
  const AppTokens.dark()
      : isDark = true,
        textPrimary = AppColors.textPrimaryDark,
        textSecondary = AppColors.textSecondaryDark,
        icon = AppColors.textPrimaryDark,
        border = const Color(0xFF382A56);

  const AppTokens.light()
      : isDark = false,
        textPrimary = AppColors.textPrimaryLight,
        textSecondary = AppColors.textSecondaryLight,
        icon = AppColors.textPrimaryLight,
        border = const Color(0xFFD8CCEE);

  final bool isDark;
  final Color textPrimary;
  final Color textSecondary;
  final Color icon;
  final Color border;
}

class AppTheme {
  const AppTheme._();

  static const Color _seed = AppColors.violet;

  static ThemeData light() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.light,
        ).copyWith(
          primary: const Color(0xFF6D0BC7),
          onPrimary: Colors.white,
          surface: AppColors.surfaceLight,
          onSurface: const Color(0xFF160B24),
          surfaceContainerHighest: const Color(0xFFEDE6F8),
          outlineVariant: const Color(0xFFD8CCEE),
        );
    return _base(scheme, Brightness.light).copyWith(
      scaffoldBackgroundColor: AppColors.canvasLight,
      cardTheme: _cardTheme(scheme, Brightness.light),
    );
  }

  static ThemeData dark() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.dark,
        ).copyWith(
          primary: AppColors.violet,
          onPrimary: Colors.white,
          secondary: AppColors.magenta,
          surface: AppColors.canvasDark,
          onSurface: const Color(0xFFF3EDFF),
          onSurfaceVariant: const Color(0xFFB9A9D8),
          surfaceContainerHighest: AppColors.surfaceHigh,
          outlineVariant: const Color(0xFF382A56),
          error: const Color(0xFFFF5C8A),
        );
    return _base(scheme, Brightness.dark).copyWith(
      scaffoldBackgroundColor: AppColors.canvasDark,
      cardTheme: _cardTheme(scheme, Brightness.dark),
    );
  }

  /// The signature brand gradient: violet into magenta, on a diagonal.
  ///
  /// Used by primary actions, the logo mark and hero surfaces alike, so a single
  /// visual signature ties the whole interface together.
  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF8A1BF9), Color(0xFFB516FA), Color(0xFFE01BD4)],
    stops: [0.0, 0.52, 1.0],
  );

  /// The primary action gradient, measured off the reference artwork's sign-in
  /// call to action: neon rose through violet to electric blue.
  ///
  /// This is the only sanctioned primary fill. Screens choose it by using
  /// [GradientButton] rather than building a gradient of their own, so the main
  /// action reads as the single brightest object on every page.
  static const LinearGradient actionGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFFFC25B6), Color(0xFFA000FF), Color(0xFF168CFD)],
    stops: [0.0, 0.52, 1.0],
  );

  /// Hairline gradient used to frame the auth fields and cards.
  static const LinearGradient neonHairline = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFF0A8A), Color(0xFFA000FF), Color(0xFF16E0FF)],
  );

  /// Gradient used by hero surfaces (KYC status, auth headers, onboarding).
  ///
  /// Kept for call-site compatibility; it now resolves to a deeper variant of the
  /// brand ramp so text stays legible on top of it.
  static LinearGradient heroGradient(Brightness brightness) =>
      brightness == Brightness.dark
      ? const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3A0E63), Color(0xFF5B1191), Color(0xFF8A14B8)],
          stops: [0.0, 0.55, 1.0],
        )
      : const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF6D0BC7), Color(0xFF9C13E0)],
        );

  /// Foreground colours for content placed on [heroGradient].
  static const Color onHero = Color(0xFFFBF7FF);
  static const Color onHeroMuted = Color(0xCCFBF7FF);

  /// Soft elevation. Light mode uses a barely-there shadow for depth; dark mode
  /// relies on a hairline border and a faint violet bloom instead, because plain
  /// shadows are invisible on a dark canvas.
  static CardThemeData _cardTheme(ColorScheme scheme, Brightness brightness) {
    final radius = BorderRadius.circular(AppRadius.lg);
    if (brightness == Brightness.dark) {
      return CardThemeData(
        // Translucent glass, not an opaque slab: the master aurora backdrop is
        // painted once at the root and must stay visible through every card.
        color: AppColors.glassFill.withValues(alpha: 0.14),
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.65)),
        ),
      );
    }
    return CardThemeData(
      color: Colors.white,
      elevation: 1.5,
      shadowColor: const Color(0x1A6D0BC7),
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: radius),
    );
  }

  /// Tuned type scale: tighter tracking and heavier weights on headings give the
  /// interface a deliberate, product-grade voice without a custom font.
  static TextTheme _textTheme(TextTheme base) => base.copyWith(
    headlineMedium: base.headlineMedium?.copyWith(
      fontWeight: FontWeight.w800,
      letterSpacing: -0.6,
    ),
    headlineSmall: base.headlineSmall?.copyWith(
      fontWeight: FontWeight.w800,
      letterSpacing: -0.4,
    ),
    titleLarge: base.titleLarge?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
    ),
    titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    titleSmall: base.titleSmall?.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: 0.1,
    ),
    bodyLarge: base.bodyLarge?.copyWith(height: 1.45),
    bodyMedium: base.bodyMedium?.copyWith(height: 1.45),
    bodySmall: base.bodySmall?.copyWith(height: 1.4),
    labelLarge: base.labelLarge?.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
    ),
  );

  static ThemeData _base(ColorScheme scheme, Brightness brightness) {
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);
    final isDark = brightness == Brightness.dark;

    return base.copyWith(
      textTheme: _textTheme(base.textTheme),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
          color: scheme.onSurface,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        // Dark fields are a glassy translucent panel framed by a faint violet
        // hairline, matching the reference artwork.
        fillColor: isDark
            ? Colors.white.withValues(alpha: 0.045)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 17,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.9),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.8),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: scheme.error, width: 1.6),
        ),
        hintStyle: TextStyle(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
        ),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(56),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(54),
          foregroundColor: scheme.onSurface,
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.9)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        side: BorderSide(color: scheme.outlineVariant),
        labelStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 12.5,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.6),
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : scheme.onSurfaceVariant,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.surfaceContainerHighest,
        ),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        elevation: 0,
        backgroundColor: isDark ? const Color(0xFF0B0518) : Colors.white,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: isDark ? 0.30 : 0.14),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 24,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          );
        }),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
    );
  }

  /// Semantic colour for a ticket status, used consistently across screens.
  ///
  /// Tuned brighter in dark mode so the pills keep their meaning against the
  /// near-black canvas.
  static Color statusColor(BuildContext context, String status) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return switch (status) {
      'pending' => isDark ? const Color(0xFFFFC24B) : const Color(0xFFB26A00),
      'in_review' => isDark ? const Color(0xFF5CC8FF) : const Color(0xFF1D6FB8),
      'replied' => isDark ? const Color(0xFF52E39B) : const Color(0xFF2E7D32),
      'closed' => scheme.onSurfaceVariant,
      _ => scheme.onSurfaceVariant,
    };
  }

  /// Soft violet bloom used under primary surfaces in dark mode.
  static List<BoxShadow> glow(
    Color color, {
    double opacity = 0.45,
    double blur = 28,
  }) => [
    BoxShadow(
      color: color.withValues(alpha: opacity),
      blurRadius: blur,
      spreadRadius: -2,
      offset: const Offset(0, 10),
    ),
  ];
}

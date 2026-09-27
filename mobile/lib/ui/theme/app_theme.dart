/// Centralised design system for Tango KYC Verification.
///
/// Colours, typography, spacing, radii, elevation and the brand gradient live
/// here, so screens stay declarative and the whole app moves together. Both
/// schemes derive from one sober seed; the status colours are the only saturated
/// accents and therefore carry meaning instead of decoration.
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
}

/// Corner radii, from chips up to hero surfaces.
abstract final class AppRadius {
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 26;
  static const double pill = 999;
}

class AppTheme {
  const AppTheme._();

  static const Color _seed = Color(0xFF2F6B5F);
  static const Color _lightSurface = Color(0xFFF6F8F7);
  static const Color _darkSurface = Color(0xFF101312);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.light);
    return _base(scheme, Brightness.light).copyWith(
      scaffoldBackgroundColor: _lightSurface,
      cardTheme: _cardTheme(scheme, Brightness.light),
    );
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark);
    return _base(scheme, Brightness.dark).copyWith(
      scaffoldBackgroundColor: _darkSurface,
      cardTheme: _cardTheme(scheme, Brightness.dark),
    );
  }

  /// Gradient used by hero surfaces (KYC status, auth headers, onboarding).
  ///
  /// Always paired with [onHero] so contrast holds in both themes.
  static LinearGradient heroGradient(Brightness brightness) => brightness == Brightness.dark
      ? const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1B3A33), Color(0xFF28604F)],
        )
      : const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2F6B5F), Color(0xFF46947D)],
        );

  /// Foreground colours for content placed on [heroGradient].
  static const Color onHero = Color(0xFFF2FBF7);
  static const Color onHeroMuted = Color(0xB3F2FBF7);

  /// Soft elevation. Light mode uses a barely-there shadow for depth; dark mode
  /// relies on a hairline border instead, because shadows are invisible on dark
  /// surfaces and would only muddy them.
  static CardThemeData _cardTheme(ColorScheme scheme, Brightness brightness) {
    final radius = BorderRadius.circular(AppRadius.lg);
    if (brightness == Brightness.dark) {
      return CardThemeData(
        color: const Color(0xFF191D1C),
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.55)),
        ),
      );
    }
    return CardThemeData(
      color: Colors.white,
      elevation: 1.5,
      shadowColor: const Color(0x14102722),
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: radius),
    );
  }

  /// Tuned type scale: tighter tracking and heavier weights on headings give the
  /// interface a deliberate, product-grade voice without a custom font.
  static TextTheme _textTheme(TextTheme base) => base.copyWith(
        headlineMedium:
            base.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
        headlineSmall:
            base.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
        titleLarge: base.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
        titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        titleSmall: base.titleSmall?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.1),
        bodyLarge: base.bodyLarge?.copyWith(height: 1.45),
        bodyMedium: base.bodyMedium?.copyWith(height: 1.45),
        bodySmall: base.bodySmall?.copyWith(height: 1.4),
        labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.2),
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
        fillColor: isDark
            ? scheme.surfaceContainerHighest.withValues(alpha: 0.35)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.8)),
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
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(54),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 0.1),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.pill)),
        side: BorderSide(color: scheme.outlineVariant),
        labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.6),
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 70,
        elevation: 0,
        backgroundColor: isDark ? const Color(0xFF161A19) : Colors.white,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: isDark ? 0.26 : 0.14),
        indicatorShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
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
    );
  }

  /// Semantic colour for a ticket status, used consistently across screens.
  static Color statusColor(BuildContext context, String status) {
    final scheme = Theme.of(context).colorScheme;
    return switch (status) {
      'pending' => const Color(0xFFB26A00),
      'in_review' => const Color(0xFF1D6FB8),
      'replied' => const Color(0xFF2E7D32),
      'closed' => scheme.onSurfaceVariant,
      _ => scheme.onSurfaceVariant,
    };
  }
}

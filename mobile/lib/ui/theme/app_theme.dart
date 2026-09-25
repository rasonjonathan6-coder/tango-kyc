/// Application theme: Material 3, sobriety, generous spacing and rounded cards.
///
/// Colours are intentionally restrained so status colours carry meaning instead
/// of decoration. Both light and dark schemes are defined explicitly.
library;

import 'package:flutter/material.dart';

class AppTheme {
  const AppTheme._();

  static const Color _seed = Color(0xFF2F6B5F);
  static const Color _lightSurface = Color(0xFFF7F8F7);
  static const Color _darkSurface = Color(0xFF111413);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.light);
    return _base(scheme).copyWith(
      scaffoldBackgroundColor: _lightSurface,
      cardTheme: _cardTheme(scheme, Colors.white),
    );
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark);
    return _base(scheme).copyWith(
      scaffoldBackgroundColor: _darkSurface,
      cardTheme: _cardTheme(scheme, const Color(0xFF1B1F1E)),
    );
  }

  static CardThemeData _cardTheme(ColorScheme scheme, Color color) => CardThemeData(
        color: color,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      );

  static ThemeData _base(ColorScheme scheme) {
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);

    return base.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.error, width: 1.6),
        ),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(54),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        side: BorderSide(color: scheme.outlineVariant),
        labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.6), space: 1),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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

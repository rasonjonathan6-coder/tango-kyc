/// Shared presentational widgets: status pills, empty/error/loading states and
/// the form field used for the two KYC inputs.
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../theme/app_theme.dart';
import 'aurora.dart';

/// A rounded, colour-coded status pill.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.status, this.compact = false});

  final KycStatus status;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = switch (status) {
      KycStatus.pending => isDark ? const Color(0xFFFFC24B) : const Color(0xFFB26A00),
      KycStatus.inReview => isDark ? const Color(0xFF5CC8FF) : const Color(0xFF1D6FB8),
      KycStatus.replied => isDark ? const Color(0xFF52E39B) : const Color(0xFF2E7D32),
      KycStatus.closed => scheme.onSurfaceVariant,
    };

    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 12, vertical: compact ? 4 : 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 7),
          Text(
            status.label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: compact ? 11.5 : 12.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// A small labelled key/value row used on detail screens.
class InfoRow extends StatelessWidget {
  const InfoRow({super.key, required this.label, required this.value, this.valueWidget});

  final String label;
  final String value;
  final Widget? valueWidget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: valueWidget ??
                SelectableText(
                  value.isEmpty ? '-' : value,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
          ),
        ],
      ),
    );
  }
}

/// Consistent empty state.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 52, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
            const SizedBox(height: 18),
            Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (action != null) ...[const SizedBox(height: 22), action!],
          ],
        ),
      ),
    );
  }
}

/// Consistent error state with a retry affordance.
class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.wifi_off_rounded, size: 52, color: theme.colorScheme.error.withValues(alpha: 0.7)),
            const SizedBox(height: 18),
            Text(
              'Something went wrong',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 22),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Réessayer'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(160, 46)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A labelled form field with consistent spacing and error presentation.
///
/// Rendered as the same glass panel as [NeonField] so the signed-in forms read
/// as one family with the authentication screens. The API and the underlying
/// [TextFormField] behaviour are unchanged.
class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.errorText,
    this.keyboardType,
    this.textInputAction,
    this.helper,
    this.autofillHints,
    this.onSubmitted,
    this.enabled = true,
    this.maxLines = 1,
    this.validator,
    this.obscureText = false,
    this.suffix,
    this.icon,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final String? errorText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final String? helper;
  final Iterable<String>? autofillHints;
  final ValueChanged<String>? onSubmitted;
  final bool enabled;
  final int maxLines;
  final String? Function(String?)? validator;
  final bool obscureText;
  final Widget? suffix;

  /// Leading glyph shown inside the field. Defaults to the neon "field" glyph so
  /// every labelled input keeps the premium look even without an explicit icon.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final glass = isDark
        ? const Color(0xFF1E143C).withValues(alpha: 0.70)
        : Colors.white;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
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
        Container(
          decoration: BoxDecoration(
            gradient: isDark ? AppTheme.neonHairline : null,
            color: isDark ? null : theme.colorScheme.outlineVariant,
            borderRadius: BorderRadius.circular(30),
          ),
          padding: EdgeInsets.all(isDark ? 1.6 : 1),
          child: Container(
            decoration: BoxDecoration(
              color: glass,
              borderRadius: BorderRadius.circular(28),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  icon ?? Icons.edit_note_rounded,
                  size: 24,
                  color: isDark
                      ? AppColors.violetBright.withValues(alpha: 0.95)
                      : theme.colorScheme.primary,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: TextFormField(
                    controller: controller,
                    enabled: enabled,
                    keyboardType: keyboardType,
                    textInputAction: textInputAction,
                    autofillHints: autofillHints,
                    maxLines: obscureText ? 1 : maxLines,
                    obscureText: obscureText,
                    onFieldSubmitted: onSubmitted,
                    validator: validator,
                    style: TextStyle(
                      color: isDark ? Colors.white : theme.colorScheme.onSurface,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: InputDecoration(
                      hintText: hint,
                      hintStyle: TextStyle(
                        color: isDark
                            ? const Color(0xFF9A88C4).withValues(alpha: 0.85)
                            : theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.8),
                        fontSize: 15.5,
                        fontWeight: FontWeight.w400,
                      ),
                      errorText: errorText,
                      helperText: helper,
                      helperStyle: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 12.5,
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
                      suffixIcon: suffix,
                      suffixIconConstraints: const BoxConstraints(
                        minWidth: 0,
                        minHeight: 0,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A lightly animated wrapper that fades and lifts its content into place.
///
/// Kept for call-site compatibility; it now delegates to the shared [Reveal].
class AnimatedEntry extends StatelessWidget {
  const AnimatedEntry({super.key, required this.child, this.delay = Duration.zero});

  final Widget child;
  final Duration delay;

  @override
  Widget build(BuildContext context) => Reveal(delay: delay, child: child);
}

/// A key/value card used to summarise a ticket.
class SummaryCard extends StatelessWidget {
  const SummaryCard({super.key, required this.children, this.title, this.trailing});

  final List<Widget> children;
  final String? title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title!,
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  ?trailing,
                ],
              ),
            if (title != null) const SizedBox(height: 6),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Formats a date with the French month names: "25 septembre 2026".
String formatDate(DateTime date) {
  const months = [
    'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
    'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
  ];
  return '${date.day} ${months[date.month - 1]} ${date.year}';
}

/// Formats a date with its time, for conversation messages.
String formatDateTime(DateTime date) {
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  return '${formatDate(date)} à $hour:$minute';
}

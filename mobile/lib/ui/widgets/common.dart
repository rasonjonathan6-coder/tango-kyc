/// Shared presentational widgets: status pills, empty/error/loading states and
/// the form field used for the two KYC inputs.
library;

import 'package:flutter/material.dart';

import '../../models/models.dart';

/// A rounded, colour-coded status pill.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.status, this.compact = false});

  final KycStatus status;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (status) {
      KycStatus.pending => const Color(0xFFB26A00),
      KycStatus.inReview => const Color(0xFF1D6FB8),
      KycStatus.replied => const Color(0xFF2E7D32),
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
                label: const Text('Try again'),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          enabled: enabled,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          autofillHints: autofillHints,
          maxLines: obscureText ? 1 : maxLines,
          obscureText: obscureText,
          onFieldSubmitted: onSubmitted,
          validator: validator,
          decoration: InputDecoration(
            hintText: hint,
            errorText: errorText,
            helperText: helper,
            suffixIcon: suffix,
          ),
        ),
      ],
    );
  }
}

/// A lightly animated card that fades and lifts its content into place.
class AnimatedEntry extends StatelessWidget {
  const AnimatedEntry({super.key, required this.child, this.delay = Duration.zero});

  final Widget child;
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 320 + delay.inMilliseconds),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(offset: Offset(0, 12 * (1 - value)), child: child),
      ),
      child: child,
    );
  }
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

/// Formats a date the way the brief shows it: "25 September 2026".
String formatDate(DateTime date) {
  const months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  return '${date.day} ${months[date.month - 1]} ${date.year}';
}

/// Formats a date with its time, for conversation messages.
String formatDateTime(DateTime date) {
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  return '${formatDate(date)} at $hour:$minute';
}

/// Modern shared components: shimmering skeletons, the KYC status hero, progress
/// stepper, notification tiles and the empty/error/success states.
///
/// Everything here is presentational only — no screen reaches the network through
/// this file, so it can be reused by user and admin surfaces alike.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

// ---------------------------------------------------------------------------
// Skeleton loading
// ---------------------------------------------------------------------------

/// A single shimmering placeholder block.
///
/// Implemented with a short, cheap animation instead of a third-party shimmer
/// package: one [AnimationController] drives an [AnimatedBuilder], so there is no
/// extra dependency and no jank on low-end devices.
class SkeletonBox extends StatefulWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height = 14,
    this.radius = AppRadius.sm,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = scheme.onSurface.withValues(alpha: 0.06);
    final highlight = scheme.onSurface.withValues(alpha: 0.11);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: Color.lerp(base, highlight, _controller.value),
          borderRadius: BorderRadius.circular(widget.radius),
        ),
      ),
    );
  }
}

/// Placeholder shaped like a request card, shown while the list loads.
class SkeletonCard extends StatelessWidget {
  const SkeletonCard({super.key, this.lines = 3});

  final int lines;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SkeletonBox(width: 92, height: 22, radius: AppRadius.pill),
                const Spacer(),
                const SkeletonBox(width: 62, height: 22, radius: AppRadius.pill),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            for (var i = 0; i < lines; i++) ...[
              SkeletonBox(width: i.isEven ? double.infinity : 180, height: 12),
              if (i != lines - 1) const SizedBox(height: AppSpacing.sm),
            ],
          ],
        ),
      ),
    );
  }
}

/// A short list of skeleton cards, for list screens in their loading state.
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.count = 3});

  final int count;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: AppSpacing.page,
      itemCount: count,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
      itemBuilder: (_, _) => const SkeletonCard(),
    );
  }
}

// ---------------------------------------------------------------------------
// KYC status hero
// ---------------------------------------------------------------------------

/// Large, immediately legible status surface for the dashboard.
///
/// This is the one deliberately bold element in the app: a brand gradient with
/// the current KYC state, so the user understands where their request stands at a
/// glance without reading any table.
class StatusHero extends StatelessWidget {
  const StatusHero({
    super.key,
    required this.title,
    required this.statusLabel,
    required this.statusColor,
    this.subtitle,
    this.step,
    this.totalSteps = 4,
    this.trailing,
  });

  final String title;
  final String statusLabel;
  final Color statusColor;
  final String? subtitle;

  /// 1-based current step. When null the stepper is hidden.
  final int? step;
  final int totalSteps;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: AppTheme.heroGradient(brightness),
        borderRadius: BorderRadius.circular(AppRadius.xl),
        boxShadow: brightness == Brightness.dark
            ? null
            : const [
                BoxShadow(
                  color: Color(0x1F2F6B5F),
                  blurRadius: 22,
                  offset: Offset(0, 10),
                ),
              ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: AppTheme.onHero,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.24)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: statusColor.computeLuminance() > 0.6 ? statusColor : Colors.white,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        statusLabel,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: AppTheme.onHero,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (subtitle != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                subtitle!,
                style: theme.textTheme.bodyMedium?.copyWith(color: AppTheme.onHeroMuted),
              ),
            ],
            if (step != null) ...[
              const SizedBox(height: AppSpacing.lg),
              _HeroStepper(step: step!, total: totalSteps),
            ],
          ],
        ),
      ),
    );
  }
}

/// Thin segmented progress bar used inside [StatusHero].
class _HeroStepper extends StatelessWidget {
  const _HeroStepper({required this.step, required this.total});

  final int step;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 1; i <= total; i++) ...[
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 420),
              curve: Curves.easeOutCubic,
              height: 5,
              decoration: BoxDecoration(
                color: i <= step
                    ? AppTheme.onHero
                    : AppTheme.onHero.withValues(alpha: 0.26),
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
            ),
          ),
          if (i != total) const SizedBox(width: 6),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Progress stepper (vertical, for detail screens)
// ---------------------------------------------------------------------------

/// One step of the manual KYC journey, rendered as a connected vertical list.
class JourneyStep {
  const JourneyStep({required this.label, required this.done, this.detail});

  final String label;
  final bool done;
  final String? detail;
}

class JourneyTimeline extends StatelessWidget {
  const JourneyTimeline({super.key, required this.steps});

  final List<JourneyStep> steps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < steps.length; i++)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Column(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: steps[i].done ? scheme.primary : Colors.transparent,
                        border: Border.all(
                          color: steps[i].done
                              ? scheme.primary
                              : scheme.outlineVariant,
                          width: 1.6,
                        ),
                        shape: BoxShape.circle,
                      ),
                      child: steps[i].done
                          ? Icon(Icons.check_rounded, size: 14, color: scheme.onPrimary)
                          : null,
                    ),
                    if (i != steps.length - 1)
                      Expanded(
                        child: Container(
                          width: 1.6,
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          color: steps[i].done
                              ? scheme.primary.withValues(alpha: 0.5)
                              : scheme.outlineVariant,
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: i == steps.length - 1 ? 0 : AppSpacing.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          steps[i].label,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: steps[i].done ? FontWeight.w600 : FontWeight.w500,
                            color: steps[i].done ? scheme.onSurface : scheme.onSurfaceVariant,
                          ),
                        ),
                        if (steps[i].detail != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            steps[i].detail!,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Notification tile
// ---------------------------------------------------------------------------

/// In-app notification row: an admin reply surfaced with a preview and a direct
/// route into the ticket. Purely presentational; the payload comes from the
/// already-validated ticket data.
class NotificationTile extends StatelessWidget {
  const NotificationTile({
    super.key,
    required this.title,
    required this.body,
    required this.ticketCode,
    required this.onTap,
    this.timestamp,
    this.unread = true,
  });

  final String title;
  final String body;
  final String ticketCode;
  final VoidCallback onTap;
  final String? timestamp;
  final bool unread;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(Icons.mark_email_unread_rounded, size: 20, color: scheme.primary),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (unread)
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: scheme.primary,
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Row(
                      children: [
                        Icon(Icons.confirmation_number_outlined,
                            size: 13, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Text(
                          ticketCode,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        if (timestamp != null) ...[
                          const Spacer(),
                          Text(
                            timestamp!,
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section header
// ---------------------------------------------------------------------------

/// Small titled section divider with an optional trailing action.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.action, this.icon});

  final String title;
  final Widget? action;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm, top: AppSpacing.xs),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 17, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 7),
          ],
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}
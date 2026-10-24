import 'package:flutter/material.dart';

import '../models/hazard_report.dart';
import '../services/hazard_ranking_service.dart';
import '../widgets/app_ui.dart';

class ReportsScreen extends StatelessWidget {
  const ReportsScreen({
    super.key,
    required this.reports,
    this.isLive = false,
    this.onReview,
  });

  final List<HazardReport> reports;
  final bool isLive;
  final ValueChanged<HazardReport>? onReview;

  IconData _iconFor(HazardType type) => switch (type) {
    HazardType.missingSidewalk => Icons.directions_walk,
    HazardType.difficultCrossing => Icons.add_road,
    HazardType.poorLighting => Icons.lightbulb_outline,
    HazardType.blockedPath => Icons.block,
    HazardType.bikeRoute => Icons.pedal_bike,
  };

  Color _colorFor(HazardType type) => switch (type) {
    HazardType.missingSidewalk => const Color(0xFF0B7F71),
    HazardType.difficultCrossing => const Color(0xFF3867B2),
    HazardType.poorLighting => const Color(0xFFB27A14),
    HazardType.blockedPath => const Color(0xFFC25D2C),
    HazardType.bikeRoute => const Color(0xFF7552A5),
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final sorted = [...reports]
      ..sort((a, b) => b.severity.compareTo(a.severity));
    final located = reports.where((report) => report.hasLocation).length;
    final rankings = const HazardRankingService().rank(reports);
    final highPriority = rankings
        .where(
          (ranking) =>
              ranking.hasLocation && ranking.priority == HazardPriority.high,
        )
        .length;
    final groupedDuplicates = rankings.fold<int>(
      0,
      (sum, ranking) => sum + ranking.duplicateCount,
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 40),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PageIntro(
                  eyebrow: 'Hazard Ranking',
                  title: 'Prioritize community concerns',
                  description: 'Nearby duplicate reports are grouped and ranked by severity, frequency, and recency. Scores support review; they do not prove a location is unsafe.',
                  icon: Icons.leaderboard_outlined,
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    LabeledIcon(
                      icon: Icons.priority_high,
                      label: 'High-priority locations',
                      value: '$highPriority identified',
                    ),
                    LabeledIcon(
                      icon: Icons.hub_outlined,
                      label: 'Ranked locations',
                      value: '${rankings.length} groups',
                    ),
                    LabeledIcon(
                      icon: Icons.content_copy_outlined,
                      label: 'Duplicate reports grouped',
                      value: '$groupedDuplicates duplicates',
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                const _ScoreExplanation(),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Text(
                      'Ranked hazard locations',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const Spacer(),
                    StatusPill(
                      label: 'Score: high to low',
                      icon: Icons.sort,
                      backgroundColor: colors.surfaceContainerHighest,
                      foregroundColor: colors.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (rankings.isEmpty)
                  _EmptyReports(isLive: isLive)
                else
                  for (var index = 0; index < rankings.length; index++) ...[
                    _RankingCard(ranking: rankings[index], rank: index + 1),
                    if (index != rankings.length - 1)
                      const SizedBox(height: 12),
                  ],
                const SizedBox(height: 28),
                Row(
                  children: [
                    Text(
                      'All reports',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const Spacer(),
                    StatusPill(
                      label: '${reports.length} reports • $located located',
                      icon: Icons.sort,
                      backgroundColor: colors.surfaceContainerHighest,
                      foregroundColor: colors.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (sorted.isEmpty)
                  _EmptyReports(isLive: isLive)
                else
                  for (var index = 0; index < sorted.length; index++) ...[
                    _ReportCard(
                      report: sorted[index],
                      icon: _iconFor(sorted[index].type),
                      accent: _colorFor(sorted[index].type),
                      onReview: onReview,
                    ),
                    if (index != sorted.length - 1) const SizedBox(height: 12),
                  ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ScoreExplanation extends StatelessWidget {
  const _ScoreExplanation();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SectionCard(
      color: colors.primaryContainer.withValues(alpha: .3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.calculate_outlined, color: colors.primary),
              const SizedBox(width: 10),
              Text(
                'How the 100-point score is calculated',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              LabeledIcon(
                icon: Icons.signal_cellular_alt,
                label: 'Severity • up to 50 points',
                value: 'Average severity ÷ 5 × 50',
              ),
              LabeledIcon(
                icon: Icons.groups_outlined,
                label: 'Frequency • up to 30 points',
                value: 'Reports ÷ 5 × 30; capped at 5',
              ),
              LabeledIcon(
                icon: Icons.schedule,
                label: 'Recency • up to 20 points',
                value: '20 / 15 / 10 / 5 / 0 by age',
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'Reports of the same hazard type within 75 meters are one location group. '
            'Recency awards 20 points at 0–7 days, 15 at 8–30, 10 at 31–90, '
            '5 at 91–180, and 0 after 180 days. High priority begins at 70; '
            'elevated begins at 45. Resolved and rejected reports are excluded.',
            style: TextStyle(color: colors.onSurfaceVariant, height: 1.45),
          ),
        ],
      ),
    );
  }
}

class _RankingCard extends StatelessWidget {
  const _RankingCard({required this.ranking, required this.rank});

  final HazardRanking ranking;
  final int rank;

  Color _priorityColor() => switch (ranking.priority) {
    HazardPriority.high => const Color(0xFFB3261E),
    HazardPriority.elevated => const Color(0xFF9A5A00),
    HazardPriority.monitor => const Color(0xFF35685F),
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final priorityColor = _priorityColor();
    return Semantics(
      container: true,
      label:
          'Rank $rank, ${ranking.type.label}, ${ranking.priority.label}, score ${ranking.totalScore.toStringAsFixed(1)} out of 100, ${ranking.reportCount} reports.',
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: priorityColor.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      '#$rank',
                      style: TextStyle(
                        color: priorityColor,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 9,
                          runSpacing: 7,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              ranking.type.label,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            StatusPill(
                              label: ranking.priority.label,
                              backgroundColor: priorityColor.withValues(
                                alpha: .12,
                              ),
                              foregroundColor: priorityColor,
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          ranking.hasLocation
                              ? '${ranking.latitude!.toStringAsFixed(5)}, ${ranking.longitude!.toStringAsFixed(5)}'
                              : 'Location unavailable',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    children: [
                      Text(
                        ranking.totalScore.toStringAsFixed(1),
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              color: priorityColor,
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                      Text(
                        '/ 100',
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  StatusPill(
                    label:
                        'Severity ${ranking.severityScore.toStringAsFixed(1)}/50',
                    icon: Icons.signal_cellular_alt,
                  ),
                  StatusPill(
                    label:
                        'Frequency ${ranking.frequencyScore.toStringAsFixed(1)}/30',
                    icon: Icons.groups_outlined,
                  ),
                  StatusPill(
                    label:
                        'Recency ${ranking.recencyScore.toStringAsFixed(1)}/20',
                    icon: Icons.schedule,
                  ),
                  StatusPill(
                    label: ranking.reportCount == 1
                        ? '1 report'
                        : '${ranking.reportCount} grouped reports',
                    icon: Icons.content_copy_outlined,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({
    required this.report,
    required this.icon,
    required this.accent,
    this.onReview,
  });

  final HazardReport report;
  final IconData icon;
  final Color accent;
  final ValueChanged<HazardReport>? onReview;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(15),
              ),
              child: Icon(icon, color: accent),
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        report.type.label,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      StatusPill(
                        label: report.status.label,
                        backgroundColor: const Color(0xFFFFE7D6),
                        foregroundColor: const Color(0xFF87400D),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Text(
                    report.description,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 16,
                    runSpacing: 6,
                    children: [
                      _MetaItem(
                        icon: Icons.signal_cellular_alt,
                        text: 'Severity ${report.severity}/5',
                      ),
                      _MetaItem(
                        icon: report.hasLocation
                            ? Icons.location_on_outlined
                            : Icons.location_off_outlined,
                        text: report.hasLocation
                            ? 'Map point selected'
                            : 'No verified location',
                      ),
                      _MetaItem(
                        icon: Icons.science_outlined,
                        text: report.isDemo ? 'Demo only' : 'Community entry',
                      ),
                      _MetaItem(
                        icon: Icons.school_outlined,
                        text: report.schoolName ?? report.schoolId,
                      ),
                      if (report.hasPhoto)
                        const _MetaItem(
                          icon: Icons.photo_outlined,
                          text: 'Photo evidence',
                        ),
                    ],
                  ),
                  if (onReview != null) ...[
                    const SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: () => onReview!(report),
                      icon: const Icon(Icons.fact_check_outlined),
                      label: const Text('Details, flags & history'),
                    ),
                  ],
                ],
              ),
            ),
            Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                shape: BoxShape.circle,
              ),
              child: Text(
                '${report.severity}',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(color: accent, fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetaItem extends StatelessWidget {
  const _MetaItem({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 5),
        Text(text, style: TextStyle(color: color, fontSize: 12)),
      ],
    );
  }
}

class _EmptyReports extends StatelessWidget {
  const _EmptyReports({required this.isLive});

  final bool isLive;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Column(
        children: [
          Icon(
            Icons.inbox_outlined,
            size: 42,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            isLive
                ? 'No visible reports yet'
                : 'Connect Supabase to load reports',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}

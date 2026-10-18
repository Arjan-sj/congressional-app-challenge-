import 'package:flutter/material.dart';

import '../models/hazard_report.dart';
import '../widgets/app_ui.dart';

class ReportsScreen extends StatelessWidget {
  const ReportsScreen({super.key, required this.reports});

  final List<HazardReport> reports;

  IconData _iconFor(HazardType type) => switch (type) {
    HazardType.missingSidewalk => Icons.directions_walk,
    HazardType.difficultCrossing => Icons.add_road,
    HazardType.blockedPath => Icons.block,
    HazardType.bikeRoute => Icons.pedal_bike,
  };

  Color _colorFor(HazardType type) => switch (type) {
    HazardType.missingSidewalk => const Color(0xFF0B7F71),
    HazardType.difficultCrossing => const Color(0xFF3867B2),
    HazardType.blockedPath => const Color(0xFFC25D2C),
    HazardType.bikeRoute => const Color(0xFF7552A5),
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final sorted = [...reports]
      ..sort((a, b) => b.severity.compareTo(a.severity));
    final located = reports.where((report) => report.hasLocation).length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 40),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const PageIntro(
                  eyebrow: 'Community observations',
                  title: 'Example reports',
                  description: 'Review fictional test records, sorted by self-reported severity. These are not validated safety scores.',
                  icon: Icons.assignment_outlined,
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    LabeledIcon(
                      icon: Icons.description_outlined,
                      label: 'Fictional entries',
                      value: '${reports.length} reports',
                    ),
                    LabeledIcon(
                      icon: Icons.location_on_outlined,
                      label: 'Selected map points',
                      value: '$located located',
                    ),
                    const LabeledIcon(
                      icon: Icons.fact_check_outlined,
                      label: 'Current environment',
                      value: 'Demo only',
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Text(
                      'All reports',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const Spacer(),
                    StatusPill(
                      label: 'Severity: high to low',
                      icon: Icons.sort,
                      backgroundColor: colors.surfaceContainerHighest,
                      foregroundColor: colors.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (sorted.isEmpty)
                  const _EmptyReports()
                else
                  for (var index = 0; index < sorted.length; index++) ...[
                    _ReportCard(
                      report: sorted[index],
                      icon: _iconFor(sorted[index].type),
                      accent: _colorFor(sorted[index].type),
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

class _ReportCard extends StatelessWidget {
  const _ReportCard({
    required this.report,
    required this.icon,
    required this.accent,
  });

  final HazardReport report;
  final IconData icon;
  final Color accent;

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
                      const _MetaItem(
                        icon: Icons.science_outlined,
                        text: 'Demo only',
                      ),
                    ],
                  ),
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
  const _EmptyReports();

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
            'No demo reports yet',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}

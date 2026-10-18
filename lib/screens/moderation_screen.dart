import 'package:flutter/material.dart';

import '../models/hazard_report.dart';
import '../models/report_moderation.dart';
import '../widgets/app_ui.dart';

class ModerationScreen extends StatefulWidget {
  const ModerationScreen({
    super.key,
    required this.reports,
    required this.flags,
    required this.onReview,
    this.isDemo = false,
  });

  final List<HazardReport> reports;
  final List<ReportFlag> flags;
  final ValueChanged<HazardReport> onReview;
  final bool isDemo;

  @override
  State<ModerationScreen> createState() => _ModerationScreenState();
}

class _ModerationScreenState extends State<ModerationScreen> {
  String _filter = 'Pending';

  @override
  Widget build(BuildContext context) {
    final flaggedIds = widget.flags
        .where((f) => f.isOpen)
        .map((f) => f.reportId)
        .toSet();
    final pending = widget.reports
        .where((r) => r.status == ReportStatus.unverified)
        .length;
    final reports =
        widget.reports
            .where(
              (r) => switch (_filter) {
                'Pending' => r.status == ReportStatus.unverified,
                'Flagged' => flaggedIds.contains(r.id),
                'All' => true,
                _ => r.status.label == _filter,
              },
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

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
                  eyebrow: 'Moderation',
                  title: 'Review community reports',
                  description: widget.isDemo
                      ? 'Demo workspace. Decisions and flags are saved in memory only; examples remain fictional.'
                      : 'Review submissions and accuracy flags. Record a reason for every decision.',
                  icon: Icons.fact_check_outlined,
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    LabeledIcon(
                      icon: Icons.inbox_outlined,
                      label: 'Awaiting review',
                      value: '$pending reports',
                    ),
                    LabeledIcon(
                      icon: Icons.flag_outlined,
                      label: 'Open accuracy flags',
                      value: '${flaggedIds.length} reports',
                    ),
                    LabeledIcon(
                      icon: Icons.inventory_2_outlined,
                      label: 'Review archive',
                      value: '${widget.reports.length} total reports',
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final filter in [
                      'Pending',
                      'Flagged',
                      'Verified',
                      'Rejected',
                      'Resolved',
                      'All',
                    ])
                      ChoiceChip(
                        label: Text(filter),
                        selected: _filter == filter,
                        onSelected: (_) => setState(() => _filter = filter),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                if (reports.isEmpty)
                  const SectionCard(child: Text('No reports in this queue.')),
                for (final report in reports) ...[
                  SectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            Text(
                              report.type.label,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            StatusPill(label: report.status.label),
                            if (flaggedIds.contains(report.id))
                              const StatusPill(
                                label: 'Accuracy flagged',
                                icon: Icons.flag_outlined,
                              ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(report.description),
                        const SizedBox(height: 8),
                        Text(
                          'Severity ${report.severity}/5 · ${report.isDemo ? 'Fictional example' : 'Community report'}',
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: () => widget.onReview(report),
                          icon: const Icon(Icons.fact_check_outlined),
                          label: const Text('Review report'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

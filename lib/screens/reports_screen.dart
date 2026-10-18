import 'package:flutter/material.dart';

import '../models/hazard_report.dart';

class ReportsScreen extends StatelessWidget {
  const ReportsScreen({super.key, required this.reports, this.isLive = false});

  final List<HazardReport> reports;
  final bool isLive;

  @override
  Widget build(BuildContext context) {
    final sorted = [...reports]
      ..sort((a, b) => b.severity.compareTo(a.severity));

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(isLive ? 'Database reports' : 'Example reports', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(isLive ? 'Reviewed entries and your pending tests only; not a validated risk score.' : 'Fictional test records, sorted by self-reported severity. This is not a validated safety score.'),
        const SizedBox(height: 16),
        for (final report in sorted)
          Card(
            child: ListTile(
              leading: CircleAvatar(child: Text('${report.severity}')),
              title: Text(report.type.label),
              subtitle: Text('${report.description}\n${report.status.label} • ${report.isDemo ? 'Test entry' : 'Community entry'}'),
              isThreeLine: true,
            ),
          ),
      ],
    );
  }
}

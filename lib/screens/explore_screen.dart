import 'package:flutter/material.dart';

import '../models/hazard_report.dart';

class ExploreScreen extends StatelessWidget {
  const ExploreScreen({super.key, required this.reports});

  final List<HazardReport> reports;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('School walking & biking', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(22),
            child: Column(
              children: [
                Icon(Icons.map_outlined, size: 62),
                SizedBox(height: 12),
                Text('School area map', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                SizedBox(height: 8),
                Text(
                  'Map integration comes next. Add flutter_map, a permitted tile provider, and verified sidewalk data.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        const Text('DEMO DATA ONLY — NOT REAL HAZARDS', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Text('${reports.length} fictional reports are loaded to test the interface.'),
        const SizedBox(height: 12),
        const ListTile(
          leading: Icon(Icons.shield_outlined),
          title: Text('Verification is required'),
          subtitle: Text('Public claims and routes must not treat unverified reports as established facts.'),
        ),
      ],
    );
  }
}

import '../models/hazard_report.dart';

/// Fictional examples to exercise the UI. Do not place these on a real map.
List<HazardReport> buildDemoReports() => [
  HazardReport(
    id: 'sample-1',
    schoolId: 'sample-school',
    type: HazardType.missingSidewalk,
    severity: 4,
    description: 'Example: sidewalk ends before a crossing.',
    createdAt: DateTime(2026, 10, 17),
  ),
  HazardReport(
    id: 'sample-2',
    schoolId: 'sample-school',
    type: HazardType.blockedPath,
    severity: 2,
    description: 'Example: a walking path is temporarily blocked.',
    createdAt: DateTime(2026, 10, 17),
  ),
];

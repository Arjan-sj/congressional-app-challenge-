import 'package:flutter_test/flutter_test.dart';
import 'package:congressional_app/models/hazard_report.dart';

void main() {
  test('reports start unverified without an invented location', () {
    final report = HazardReport(
      id: 'test-1',
      schoolId: 'sample-school',
      type: HazardType.blockedPath,
      severity: 3,
      description: 'Fictional example',
      createdAt: DateTime(2026, 10, 17),
    );

    expect(report.status, ReportStatus.unverified);
    expect(report.hasLocation, isFalse);
    expect(report.isDemo, isFalse);
  });
}

import 'package:congressional_app/models/hazard_report.dart';
import 'package:congressional_app/services/hazard_avoidance_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  HazardReport report({
    required String id,
    required ReportStatus status,
    double? latitude = 42,
    double? longitude = -88,
    bool isDemo = false,
  }) => HazardReport(
    id: id,
    schoolId: 'school',
    type: HazardType.blockedPath,
    severity: 3,
    description: 'Observed path concern',
    createdAt: DateTime(2026),
    status: status,
    latitude: latitude,
    longitude: longitude,
    isDemo: isDemo,
  );

  test('avoids active real reports and ignores inactive records', () {
    const service = HazardAvoidanceService();
    final active = service.activeReports([
      report(id: 'unverified', status: ReportStatus.unverified),
      report(id: 'verified', status: ReportStatus.verified),
      report(id: 'resolved', status: ReportStatus.resolved),
      report(id: 'rejected', status: ReportStatus.rejected),
      report(
        id: 'missing-location',
        status: ReportStatus.verified,
        latitude: null,
        longitude: null,
      ),
      report(id: 'demo', status: ReportStatus.verified, isDemo: true),
    ]);

    expect(active.map((item) => item.id), ['unverified', 'verified']);
    expect(HazardAvoidanceService.radiusMeters, 100);
  });

  test('keeps unique active reports in the route area', () {
    const service = HazardAvoidanceService();
    final locations = service.locationsForRoute(
      reports: [
        report(
          id: 'inside',
          status: ReportStatus.verified,
          latitude: 42.005,
          longitude: -88.105,
        ),
        report(
          id: 'duplicate',
          status: ReportStatus.unverified,
          latitude: 42.005,
          longitude: -88.105,
        ),
        report(
          id: 'far-away',
          status: ReportStatus.verified,
          latitude: 10,
          longitude: 10,
        ),
      ],
      origin: const LatLng(42, -88.1),
      destination: const LatLng(42.01, -88.11),
    );

    expect(locations, [const LatLng(42.005, -88.105)]);
  });
}

import 'package:congressional_app/models/geo_bounds.dart';
import 'package:congressional_app/models/hazard_report.dart';
import 'package:congressional_app/models/osm_infrastructure.dart';
import 'package:congressional_app/models/safety_route.dart';
import 'package:congressional_app/services/route_safety_scorer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  const route = RouteCandidate(
    id: 'walking-0',
    profile: RouteProfile.walking,
    points: [LatLng(42, -88), LatLng(42.01, -88)],
    distanceMeters: 1200,
    durationSeconds: 900,
  );
  final verifiedHazard = HazardReport(
    id: 'verified',
    schoolId: 'sample-school',
    type: HazardType.difficultCrossing,
    severity: 3,
    description: 'Verified concern near the route',
    createdAt: DateTime(2026),
    status: ReportStatus.verified,
    latitude: 42.005,
    longitude: -88,
    isDemo: false,
  );
  final unverifiedHazard = HazardReport(
    id: 'pending',
    schoolId: 'sample-school',
    type: HazardType.blockedPath,
    severity: 5,
    description: 'Pending concern near the route',
    createdAt: DateTime(2026),
    latitude: 42.005,
    longitude: -88,
    isDemo: false,
  );

  test(
    'scores only verified unresolved hazards and rewards mapped infrastructure',
    () {
      final infrastructure = InfrastructureSnapshot(
        bounds: const GeoBounds(
          south: 41.99,
          west: -88.01,
          north: 42.02,
          east: -87.99,
        ),
        features: const [
          OsmMapFeature(
            id: 'way/1/sidewalk',
            type: InfrastructureType.sidewalk,
            points: [LatLng(42, -88), LatLng(42.01, -88)],
          ),
        ],
        fetchedAt: DateTime(2026),
      );

      final result = const RouteSafetyScorer()
          .score(
            routes: const [route],
            hazards: [verifiedHazard, unverifiedHazard],
            infrastructure: infrastructure,
          )
          .single;

      expect(result.nearbyVerifiedHazards, 1);
      expect(result.hazardPenalty, 12);
      expect(result.infrastructureCoverage, 1);
      expect(result.infrastructureBonus, 20);
      expect(result.score, 88);
      expect(result.infrastructureDataComplete, isTrue);
    },
  );

  test('treats missing infrastructure as unknown without a penalty', () {
    final result = const RouteSafetyScorer()
        .score(routes: const [route], hazards: const [])
        .single;

    expect(result.infrastructureCoverage, isNull);
    expect(result.infrastructureBonus, 0);
    expect(result.score, 80);
    expect(result.infrastructureDataComplete, isFalse);
  });
  test('route issue proximity includes active non-demo reports only', () {
    const scorer = RouteSafetyScorer();
    final demo = HazardReport(
      id: 'demo', schoolId: 'x', type: HazardType.blockedPath,
      severity: 2, description: 'Fictional', createdAt: DateTime(2026),
      latitude: 42.005, longitude: -88, isDemo: true,
    );
    final resolved = HazardReport(
      id: 'resolved', schoolId: 'x', type: HazardType.blockedPath,
      severity: 2, description: 'Resolved', createdAt: DateTime(2026),
      latitude: 42.005, longitude: -88, status: ReportStatus.resolved,
    );
    final far = HazardReport(
      id: 'far', schoolId: 'x', type: HazardType.blockedPath,
      severity: 2, description: 'Far away', createdAt: DateTime(2026),
      latitude: 42.3, longitude: -88,
    );
    final result = scorer.reportsNearRoute(route.points, [
      verifiedHazard, unverifiedHazard, demo, resolved, far,
    ]);
    expect(result.map((e) => e.id), containsAll(['verified', 'pending']));
    expect(result.length, 2);
  });

}

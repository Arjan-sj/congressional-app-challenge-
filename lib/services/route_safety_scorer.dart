import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../models/geo_bounds.dart';
import '../models/hazard_report.dart';
import '../models/osm_infrastructure.dart';
import '../models/safety_route.dart';

class RouteSafetyScorer {
  const RouteSafetyScorer();

  List<RouteSafetyAssessment> score({
    required List<RouteCandidate> routes,
    required List<HazardReport> hazards,
    InfrastructureSnapshot? infrastructure,
  }) {
    final shortestByProfile = <RouteProfile, double>{};
    for (final route in routes) {
      final current = shortestByProfile[route.profile];
      if (current == null || route.distanceMeters < current) {
        shortestByProfile[route.profile] = route.distanceMeters;
      }
    }
    final verifiedHazards = hazards.where(
      (hazard) => hazard.status == ReportStatus.verified && hazard.hasLocation,
    );

    return routes
        .map((route) {
          final relevantFeatures = infrastructure == null
              ? const <OsmMapFeature>[]
              : infrastructure.features
                    .where(
                      (feature) => switch (route.profile) {
                        RouteProfile.walking =>
                          feature.type == InfrastructureType.sidewalk ||
                              feature.type == InfrastructureType.crossing,
                        RouteProfile.cycling =>
                          feature.type == InfrastructureType.bikePath ||
                              feature.type == InfrastructureType.bikeLane,
                      },
                    )
                    .toList(growable: false);
          final nearbyHazards = verifiedHazards
              .where(
                (hazard) =>
                    _distanceToRoute(
                      LatLng(hazard.latitude!, hazard.longitude!),
                      route.points,
                    ) <=
                    50,
              )
              .toList(growable: false);
          final hazardPenalty = math.min<double>(
            40,
            nearbyHazards.fold<double>(
              0,
              (total, hazard) => total + hazard.severity * 4,
            ),
          );
          final shortest = shortestByProfile[route.profile]!;
          final distancePenalty = math.min<double>(
            15,
            math.max(0, route.distanceMeters / shortest - 1) * 20,
          );
          final coverage = relevantFeatures.isEmpty
              ? null
              : _coverage(route.points, relevantFeatures);
          final infrastructureBonus = (coverage ?? 0) * 20;
          final score =
              (80 - distancePenalty - hazardPenalty + infrastructureBonus)
                  .round()
                  .clamp(0, 100);
          final routeBounds = _routeBounds(route.points);
          return RouteSafetyAssessment(
            route: route,
            score: score,
            distancePenalty: distancePenalty,
            hazardPenalty: hazardPenalty,
            infrastructureBonus: infrastructureBonus,
            nearbyVerifiedHazards: nearbyHazards.length,
            infrastructureCoverage: coverage,
            infrastructureDataComplete:
                infrastructure?.bounds.containsBounds(routeBounds) ?? false,
          );
        })
        .toList(growable: false)
      ..sort((a, b) => b.score.compareTo(a.score));
  }

  double _coverage(List<LatLng> route, List<OsmMapFeature> infrastructure) {
    final sampleEvery = math.max(1, (route.length / 150).ceil());
    var samples = 0;
    var mapped = 0;
    for (var index = 0; index < route.length; index += sampleEvery) {
      samples++;
      if (infrastructure.any(
        (feature) => _distanceToRoute(route[index], feature.points) <= 30,
      )) {
        mapped++;
      }
    }
    return samples == 0 ? 0 : mapped / samples;
  }

  GeoBounds _routeBounds(List<LatLng> points) => GeoBounds(
    south: points.map((point) => point.latitude).reduce(math.min),
    west: points.map((point) => point.longitude).reduce(math.min),
    north: points.map((point) => point.latitude).reduce(math.max),
    east: points.map((point) => point.longitude).reduce(math.max),
  );

  double _distanceToRoute(LatLng point, List<LatLng> route) {
    if (route.length == 1) {
      return const Distance().as(LengthUnit.Meter, point, route.first);
    }
    var nearest = double.infinity;
    for (var index = 1; index < route.length; index++) {
      nearest = math.min(
        nearest,
        _distanceToSegment(point, route[index - 1], route[index]),
      );
    }
    return nearest;
  }

  double _distanceToSegment(LatLng point, LatLng start, LatLng end) {
    const earthRadius = 6371000.0;
    final referenceLatitude =
        (point.latitude + start.latitude + end.latitude) / 3 * math.pi / 180;
    OffsetMeters project(LatLng value) => OffsetMeters(
      earthRadius *
          value.longitude *
          math.pi /
          180 *
          math.cos(referenceLatitude),
      earthRadius * value.latitude * math.pi / 180,
    );
    final p = project(point);
    final a = project(start);
    final b = project(end);
    final dx = b.x - a.x;
    final dy = b.y - a.y;
    final lengthSquared = dx * dx + dy * dy;
    if (lengthSquared == 0) {
      return math.sqrt(math.pow(p.x - a.x, 2) + math.pow(p.y - a.y, 2));
    }
    final t = (((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared).clamp(
      0.0,
      1.0,
    );
    final nearestX = a.x + t * dx;
    final nearestY = a.y + t * dy;
    return math.sqrt(math.pow(p.x - nearestX, 2) + math.pow(p.y - nearestY, 2));
  }
}

class OffsetMeters {
  const OffsetMeters(this.x, this.y);
  final double x;
  final double y;
}

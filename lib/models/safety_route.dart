import 'package:latlong2/latlong.dart';

enum RouteProfile {
  walking('Walking', 'foot-walking'),
  cycling('Cycling', 'cycling-regular');

  const RouteProfile(this.label, this.apiValue);
  final String label;
  final String apiValue;
}

class RouteCandidate {
  const RouteCandidate({
    required this.id,
    required this.profile,
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
  });

  final String id;
  final RouteProfile profile;
  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;
}

class RouteSafetyAssessment {
  const RouteSafetyAssessment({
    required this.route,
    required this.score,
    required this.distancePenalty,
    required this.hazardPenalty,
    required this.infrastructureBonus,
    required this.nearbyVerifiedHazards,
    required this.infrastructureCoverage,
    required this.infrastructureDataComplete,
  });

  final RouteCandidate route;
  final int score;
  final double distancePenalty;
  final double hazardPenalty;
  final double infrastructureBonus;
  final int nearbyVerifiedHazards;
  final double? infrastructureCoverage;
  final bool infrastructureDataComplete;
}

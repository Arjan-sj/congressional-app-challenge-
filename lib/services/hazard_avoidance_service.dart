import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../models/hazard_report.dart';

class HazardAvoidanceService {
  const HazardAvoidanceService();

  static const radiusMeters = 100.0;

  List<HazardReport> activeReports(Iterable<HazardReport> reports) => reports
      .where((report) => !report.isDemo && report.hasLocation)
      .where(
        (report) =>
            report.status == ReportStatus.unverified ||
            report.status == ReportStatus.verified,
      )
      .toList(growable: false);

  List<LatLng> activeLocations(Iterable<HazardReport> reports) =>
      activeReports(reports)
          .map((report) => LatLng(report.latitude!, report.longitude!))
          .toList(growable: false);

  List<LatLng> locationsForRoute({
    required Iterable<HazardReport> reports,
    required LatLng origin,
    required LatLng destination,
    double paddingMeters = 2000,
  }) {
    final midpointLatitude = (origin.latitude + destination.latitude) / 2;
    final latitudePadding = paddingMeters / 111320;
    final longitudeScale = math.cos(midpointLatitude * math.pi / 180).abs();
    final longitudePadding =
        paddingMeters / (111320 * math.max(longitudeScale, 0.01));
    final south =
        math.min(origin.latitude, destination.latitude) - latitudePadding;
    final north =
        math.max(origin.latitude, destination.latitude) + latitudePadding;
    final west =
        math.min(origin.longitude, destination.longitude) - longitudePadding;
    final east =
        math.max(origin.longitude, destination.longitude) + longitudePadding;
    final unique = <String, LatLng>{};
    for (final location in activeLocations(reports)) {
      if (!location.latitude.isFinite ||
          !location.longitude.isFinite ||
          location.latitude < -90 ||
          location.latitude > 90 ||
          location.longitude < -180 ||
          location.longitude > 180 ||
          location.latitude < south ||
          location.latitude > north ||
          location.longitude < west ||
          location.longitude > east) {
        continue;
      }
      final key =
          '${location.latitude.toStringAsFixed(6)},${location.longitude.toStringAsFixed(6)}';
      unique[key] = location;
    }
    return unique.values.toList(growable: false);
  }
}

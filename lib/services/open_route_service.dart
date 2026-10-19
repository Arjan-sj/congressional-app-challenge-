import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/safety_route.dart';
import 'hazard_avoidance_service.dart';

enum RouteFailure {
  missingApiKey,
  unauthorized,
  rateLimited,
  unavailable,
  noRoute,
  malformed,
  endpointInsideHazard,
}

class RouteServiceException implements Exception {
  const RouteServiceException(this.failure, this.message);

  final RouteFailure failure;
  final String message;

  @override
  String toString() => message;
}

class OpenRouteService {
  OpenRouteService({
    http.Client? client,
    String? apiKey,
    Uri? baseUri,
    this.requestTimeout = const Duration(seconds: 25),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       apiKey =
           apiKey ?? const String.fromEnvironment('OPENROUTESERVICE_API_KEY'),
       baseUri = baseUri ?? Uri.parse('https://api.openrouteservice.org');

  final http.Client _client;
  final bool _ownsClient;
  final String apiKey;
  final Uri baseUri;
  final Duration requestTimeout;

  static const _avoidanceCircleSegments = 24;

  bool get isConfigured => apiKey.trim().isNotEmpty;

  Future<List<RouteCandidate>> compare({
    required LatLng origin,
    required LatLng destination,
    Iterable<LatLng> avoidLocations = const [],
  }) async {
    if (!isConfigured) {
      throw const RouteServiceException(
        RouteFailure.missingApiKey,
        'Add OPENROUTESERVICE_API_KEY with --dart-define to compare routes.',
      );
    }
    final results = await Future.wait([
      fetchRoutes(
        origin: origin,
        destination: destination,
        profile: RouteProfile.walking,
        avoidLocations: avoidLocations,
      ),
      fetchRoutes(
        origin: origin,
        destination: destination,
        profile: RouteProfile.cycling,
        avoidLocations: avoidLocations,
      ),
    ]);
    return [for (final routes in results) ...routes];
  }

  Future<List<RouteCandidate>> fetchRoutes({
    required LatLng origin,
    required LatLng destination,
    required RouteProfile profile,
    Iterable<LatLng> avoidLocations = const [],
  }) async {
    if (!isConfigured) {
      throw const RouteServiceException(
        RouteFailure.missingApiKey,
        'OpenRouteService is not configured.',
      );
    }
    final endpoint = baseUri.replace(
      path: '/v2/directions/${profile.apiValue}/geojson',
    );
    final relevantAvoidLocations = _normalizeAvoidLocations(avoidLocations);
    _validateRoutePoints(origin, destination, relevantAvoidLocations);
    final requestBody = <String, dynamic>{
      'coordinates': [
        [origin.longitude, origin.latitude],
        [destination.longitude, destination.latitude],
      ],
      'alternative_routes': {
        'target_count': 2,
        'share_factor': 0.7,
        'weight_factor': 1.6,
      },
      if (relevantAvoidLocations.isNotEmpty)
        'options': {
          'avoid_polygons': _avoidanceGeometry(relevantAvoidLocations),
        },
    };
    final response = await _client
        .post(
          endpoint,
          headers: {
            'Accept': 'application/geo+json, application/json',
            'Authorization': apiKey,
            'Content-Type': 'application/json; charset=utf-8',
          },
          body: jsonEncode(requestBody),
        )
        .timeout(requestTimeout);

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const RouteServiceException(
        RouteFailure.unauthorized,
        'OpenRouteService rejected the API key. Check OPENROUTESERVICE_API_KEY.',
      );
    }
    if (response.statusCode == 429) {
      throw const RouteServiceException(
        RouteFailure.rateLimited,
        'OpenRouteService rate limit reached. Wait before comparing again.',
      );
    }
    if (response.statusCode >= 500) {
      throw const RouteServiceException(
        RouteFailure.unavailable,
        'OpenRouteService is temporarily unavailable.',
      );
    }
    if (response.statusCode == 400 || response.statusCode == 404) {
      throw const RouteServiceException(
        RouteFailure.noRoute,
        'No route could avoid the active 100 m report areas. Try moving an endpoint or selecting a shorter trip.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RouteServiceException(
        RouteFailure.unavailable,
        'Route request failed (${response.statusCode}).',
      );
    }

    try {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final features = json['features'] as List<dynamic>? ?? const [];
      return [
        for (var index = 0; index < features.length; index++)
          _decodeRoute(
            features[index] as Map<String, dynamic>,
            profile,
            index,
            relevantAvoidLocations.length,
          ),
      ];
    } on FormatException catch (error) {
      throw RouteServiceException(
        RouteFailure.malformed,
        'OpenRouteService returned unreadable route data: $error',
      );
    } on TypeError {
      throw const RouteServiceException(
        RouteFailure.malformed,
        'OpenRouteService returned an unexpected route response.',
      );
    }
  }

  RouteCandidate _decodeRoute(
    Map<String, dynamic> feature,
    RouteProfile profile,
    int index,
    int avoidedHazards,
  ) {
    final geometry = feature['geometry'] as Map<String, dynamic>;
    final coordinates = geometry['coordinates'] as List<dynamic>;
    final points = coordinates
        .map((coordinate) {
          final pair = coordinate as List<dynamic>;
          return LatLng(
            (pair[1] as num).toDouble(),
            (pair[0] as num).toDouble(),
          );
        })
        .toList(growable: false);
    final properties = feature['properties'] as Map<String, dynamic>;
    final summary = properties['summary'] as Map<String, dynamic>;
    if (points.length < 2) {
      throw const FormatException('Route has no geometry.');
    }
    return RouteCandidate(
      id: '${profile.name}-$index',
      profile: profile,
      points: points,
      distanceMeters: (summary['distance'] as num).toDouble(),
      durationSeconds: (summary['duration'] as num).toDouble(),
      avoidedHazards: avoidedHazards,
    );
  }

  List<LatLng> _normalizeAvoidLocations(Iterable<LatLng> locations) {
    final unique = <String, LatLng>{};
    for (final location in locations) {
      if (!location.latitude.isFinite ||
          !location.longitude.isFinite ||
          location.latitude < -90 ||
          location.latitude > 90 ||
          location.longitude < -180 ||
          location.longitude > 180) {
        continue;
      }
      final key =
          '${location.latitude.toStringAsFixed(6)},${location.longitude.toStringAsFixed(6)}';
      unique[key] = location;
    }
    return unique.values.toList(growable: false);
  }

  void _validateRoutePoints(
    LatLng origin,
    LatLng destination,
    List<LatLng> avoidLocations,
  ) {
    const distance = Distance();
    for (final location in avoidLocations) {
      final originDistance = distance.as(LengthUnit.Meter, origin, location);
      final destinationDistance = distance.as(
        LengthUnit.Meter,
        destination,
        location,
      );
      if (originDistance < HazardAvoidanceService.radiusMeters ||
          destinationDistance < HazardAvoidanceService.radiusMeters) {
        throw const RouteServiceException(
          RouteFailure.endpointInsideHazard,
          'The route start or destination is within 100 m of an active report. Move the point outside the highlighted area.',
        );
      }
    }
  }

  Map<String, dynamic> _avoidanceGeometry(List<LatLng> locations) {
    final polygons = [
      for (final location in locations) [_circleRing(location)],
    ];
    if (polygons.length == 1) {
      return {'type': 'Polygon', 'coordinates': polygons.single};
    }
    return {'type': 'MultiPolygon', 'coordinates': polygons};
  }

  List<List<double>> _circleRing(LatLng center) {
    const distance = Distance();
    final ring = <List<double>>[];
    for (var index = 0; index < _avoidanceCircleSegments; index++) {
      final point = distance.offset(
        center,
        HazardAvoidanceService.radiusMeters,
        360 * index / _avoidanceCircleSegments,
      );
      ring.add([point.longitude, point.latitude]);
    }
    ring.add(List<double>.from(ring.first));
    return ring;
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

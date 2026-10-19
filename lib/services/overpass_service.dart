import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/geo_bounds.dart';
import '../models/osm_infrastructure.dart';

enum OverpassFailure { invalidBounds, rateLimited, unavailable, malformed }

class OverpassException implements Exception {
  const OverpassException(this.failure, this.message);

  final OverpassFailure failure;
  final String message;

  @override
  String toString() => message;
}

class OverpassService {
  OverpassService({
    http.Client? client,
    Uri? endpoint,
    this.cacheTtl = const Duration(minutes: 10),
    this.requestTimeout = const Duration(seconds: 28),
    this.maxCacheEntries = 20,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       endpoint =
           endpoint ??
           Uri.parse(
             const String.fromEnvironment(
               'OVERPASS_URL',
               defaultValue: 'https://overpass-api.de/api/interpreter',
             ),
           );

  final http.Client _client;
  final bool _ownsClient;
  final Uri endpoint;
  final Duration cacheTtl;
  final Duration requestTimeout;
  final int maxCacheEntries;
  final Map<String, InfrastructureSnapshot> _cache = {};
  final Map<String, Future<InfrastructureSnapshot>> _inFlight = {};

  Future<InfrastructureSnapshot> fetch(
    GeoBounds visibleBounds, {
    bool forceRefresh = false,
  }) {
    if (visibleBounds.latitudeSpan > .18 || visibleBounds.longitudeSpan > .24) {
      throw const OverpassException(
        OverpassFailure.invalidBounds,
        'Zoom in farther to load nearby infrastructure.',
      );
    }

    final queryBounds = visibleBounds.expanded(.2);
    final now = DateTime.now();
    if (!forceRefresh) {
      for (final snapshot in _cache.values) {
        if (snapshot.bounds.containsBounds(visibleBounds) &&
            now.difference(snapshot.fetchedAt) < cacheTtl) {
          return Future.value(snapshot);
        }
      }
    }

    final key = queryBounds.cacheKey;
    final existingRequest = _inFlight[key];
    if (!forceRefresh && existingRequest != null) return existingRequest;
    final request = _fetchRemote(queryBounds);
    _inFlight[key] = request;
    return request.whenComplete(() => _inFlight.remove(key));
  }

  Future<InfrastructureSnapshot> _fetchRemote(GeoBounds bounds) async {
    final response = await _client
        .post(
          endpoint,
          headers: const {'Accept': 'application/json'},
          body: {'data': _query(bounds)},
        )
        .timeout(requestTimeout);

    if (response.statusCode == 429) {
      throw const OverpassException(
        OverpassFailure.rateLimited,
        'OpenStreetMap infrastructure is busy. Wait about 30 seconds, then retry.',
      );
    }
    if (response.statusCode == 504 || response.statusCode >= 500) {
      throw const OverpassException(
        OverpassFailure.unavailable,
        'OpenStreetMap infrastructure is temporarily unavailable. The basemap and hazards still work.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw OverpassException(
        OverpassFailure.unavailable,
        'Infrastructure request failed (${response.statusCode}).',
      );
    }

    try {
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final elements = json['elements'] as List<dynamic>? ?? const [];
      final features = <OsmMapFeature>[];
      for (final raw in elements.whereType<Map<String, dynamic>>()) {
        features.addAll(_decodeElement(raw));
      }
      final snapshot = InfrastructureSnapshot(
        bounds: bounds,
        features: List.unmodifiable(features),
        fetchedAt: DateTime.now(),
      );
      _remember(bounds.cacheKey, snapshot);
      return snapshot;
    } on FormatException catch (error) {
      throw OverpassException(
        OverpassFailure.malformed,
        'OpenStreetMap returned unreadable infrastructure data: $error',
      );
    } on TypeError {
      throw const OverpassException(
        OverpassFailure.malformed,
        'OpenStreetMap returned an unexpected infrastructure response.',
      );
    }
  }

  void _remember(String key, InfrastructureSnapshot snapshot) {
    _cache.remove(key);
    _cache[key] = snapshot;
    while (_cache.length > maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  String _query(GeoBounds bounds) {
    final bbox = bounds.toString();
    return '''
[out:json][timeout:20];
(
  nwr["amenity"="school"]($bbox);
  way["highway"="footway"]["footway"="sidewalk"]($bbox);
  way["sidewalk"]($bbox);
  nwr["highway"="crossing"]($bbox);
  way["highway"="cycleway"]($bbox);
  way["cycleway"]($bbox);
);
out center tags geom;
''';
  }

  List<OsmMapFeature> _decodeElement(Map<String, dynamic> element) {
    final elementType = element['type']?.toString() ?? 'element';
    final id = '$elementType/${element['id']}';
    final tags = (element['tags'] as Map<String, dynamic>? ?? const {}).map(
      (key, value) => MapEntry(key, value.toString()),
    );
    final points = _points(element);
    if (points.isEmpty) return const [];

    final types = <InfrastructureType>{};
    if (tags['amenity'] == 'school') {
      types.add(InfrastructureType.school);
    }
    if (tags['highway'] == 'crossing') {
      types.add(InfrastructureType.crossing);
    }
    if (tags['highway'] == 'footway' && tags['footway'] == 'sidewalk' ||
        _isPositiveLinearTag(tags['sidewalk'])) {
      types.add(InfrastructureType.sidewalk);
    }
    if (tags['highway'] == 'cycleway') {
      types.add(InfrastructureType.bikePath);
    } else if (_isPositiveLinearTag(tags['cycleway'])) {
      types.add(InfrastructureType.bikeLane);
    }

    return [
      for (final type in types)
        OsmMapFeature(
          id: '$id/${type.name}',
          type: type,
          points:
              type == InfrastructureType.school ||
                  type == InfrastructureType.crossing
              ? [_center(element, points)]
              : List.unmodifiable(points),
          tags: Map.unmodifiable(tags),
        ),
    ];
  }

  bool _isPositiveLinearTag(String? value) {
    if (value == null || value.isEmpty) return false;
    return !const {'no', 'none', 'separate', 'unknown'}.contains(value);
  }

  List<LatLng> _points(Map<String, dynamic> element) {
    final geometry = element['geometry'] as List<dynamic>?;
    if (geometry != null) {
      final points = geometry
          .whereType<Map<String, dynamic>>()
          .map((point) {
            final latitude = point['lat'] as num?;
            final longitude = point['lon'] as num?;
            return latitude == null || longitude == null
                ? null
                : LatLng(latitude.toDouble(), longitude.toDouble());
          })
          .whereType<LatLng>()
          .toList(growable: false);
      if (points.isNotEmpty) return points;
    }
    final latitude = element['lat'] as num?;
    final longitude = element['lon'] as num?;
    if (latitude != null && longitude != null) {
      return [LatLng(latitude.toDouble(), longitude.toDouble())];
    }
    final center = element['center'] as Map<String, dynamic>?;
    final centerLatitude = center?['lat'] as num?;
    final centerLongitude = center?['lon'] as num?;
    if (centerLatitude != null && centerLongitude != null) {
      return [LatLng(centerLatitude.toDouble(), centerLongitude.toDouble())];
    }
    return const [];
  }

  LatLng _center(Map<String, dynamic> element, List<LatLng> points) {
    final center = element['center'] as Map<String, dynamic>?;
    final latitude = center?['lat'] as num?;
    final longitude = center?['lon'] as num?;
    if (latitude != null && longitude != null) {
      return LatLng(latitude.toDouble(), longitude.toDouble());
    }
    if (points.length == 1) return points.first;
    var latitudeTotal = 0.0;
    var longitudeTotal = 0.0;
    for (final point in points) {
      latitudeTotal += point.latitude;
      longitudeTotal += point.longitude;
    }
    return LatLng(
      latitudeTotal / points.length,
      longitudeTotal / points.length,
    );
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

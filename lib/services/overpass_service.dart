import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

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
    List<Uri> fallbackEndpoints = const [],
    this.cacheTtl = const Duration(minutes: 10),
    this.requestTimeout = const Duration(seconds: 28),
    this.maxCacheEntries = 20,
    this.chunkRows = 2,
    this.chunkColumns = 2,
    this.maxConcurrentRequests = 2,
    this.maxRetries = 1,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       assert(chunkRows > 0),
       assert(chunkColumns > 0),
       assert(maxConcurrentRequests > 0),
       assert(maxRetries >= 0),
       endpoints = List.unmodifiable(
         _resolveEndpoints(endpoint, fallbackEndpoints),
       );

  final http.Client _client;
  final bool _ownsClient;
  final List<Uri> endpoints;
  final Duration cacheTtl;
  final Duration requestTimeout;
  final int maxCacheEntries;
  final int chunkRows;
  final int chunkColumns;
  final int maxConcurrentRequests;
  final int maxRetries;
  final Map<String, InfrastructureSnapshot> _cache = {};
  final Map<String, Future<InfrastructureSnapshot>> _inFlight = {};

  static List<Uri> _resolveEndpoints(
    Uri? endpoint,
    List<Uri> fallbackEndpoints,
  ) {
    if (endpoint != null) return [endpoint, ...fallbackEndpoints];
    const configured = String.fromEnvironment('OVERPASS_URL');
    if (configured.isNotEmpty) {
      final configuredEndpoint = Uri.parse(configured);
      return [
        configuredEndpoint,
        if (configuredEndpoint.host == 'overpass-api.de' ||
            configuredEndpoint.host.endsWith('.overpass-api.de'))
          Uri.parse('https://maps.mail.ru/osm/tools/overpass/api/interpreter'),
        ...fallbackEndpoints,
      ];
    }
    return [
      // Both are public, global Overpass instances. The first also supplies
      // CORS headers required by Flutter Web.
      Uri.parse('https://maps.mail.ru/osm/tools/overpass/api/interpreter'),
      Uri.parse('https://overpass-api.de/api/interpreter'),
      ...fallbackEndpoints,
    ];
  }

  Future<InfrastructureSnapshot> fetch(
    GeoBounds visibleBounds, {
    bool forceRefresh = false,
    void Function(
      InfrastructureSnapshot snapshot,
      int completedChunks,
      int totalChunks,
    )?
    onProgress,
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
    final request = _fetchRemote(queryBounds, onProgress: onProgress);
    _inFlight[key] = request;
    return request.whenComplete(() => _inFlight.remove(key));
  }

  Future<InfrastructureSnapshot> _fetchRemote(
    GeoBounds bounds, {
    void Function(
      InfrastructureSnapshot snapshot,
      int completedChunks,
      int totalChunks,
    )?
    onProgress,
  }) async {
    final chunks = _split(bounds);
    final featuresById = <String, OsmMapFeature>{};
    Object? firstError;
    StackTrace? firstStackTrace;
    var nextChunk = 0;
    var completedChunks = 0;
    var rateLimited = false;

    Future<void> worker() async {
      while (true) {
        if (rateLimited) return;
        final index = nextChunk++;
        if (index >= chunks.length) return;
        try {
          final features = await _fetchChunk(chunks[index]);
          for (final feature in features) {
            // Adjacent bounding boxes include their shared edge. OSM element IDs
            // keep those duplicate responses from being rendered twice.
            featuresById[feature.id] = feature;
          }
          completedChunks++;
          onProgress?.call(
            InfrastructureSnapshot(
              bounds: bounds,
              features: List.unmodifiable(featuresById.values),
              fetchedAt: DateTime.now(),
            ),
            completedChunks,
            chunks.length,
          );
        } catch (error, stackTrace) {
          firstError ??= error;
          firstStackTrace ??= stackTrace;
          if (error is OverpassException &&
              error.failure == OverpassFailure.rateLimited) {
            // Do not queue more work after the endpoint asks us to back off.
            rateLimited = true;
          }
        }
      }
    }

    await Future.wait([
      for (
        var workerIndex = 0;
        workerIndex < math.min(maxConcurrentRequests, chunks.length);
        workerIndex++
      )
        worker(),
    ]);

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }

    final snapshot = InfrastructureSnapshot(
      bounds: bounds,
      features: List.unmodifiable(featuresById.values),
      fetchedAt: DateTime.now(),
    );
    _remember(bounds.cacheKey, snapshot);
    return snapshot;
  }

  Future<List<OsmMapFeature>> _fetchChunk(GeoBounds bounds) async {
    for (var attempt = 0; ; attempt++) {
      final requestEndpoint = endpoints[attempt % endpoints.length];
      try {
        return await _requestChunk(bounds, requestEndpoint);
      } on TimeoutException {
        if (attempt >= maxRetries) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 300 * (attempt + 1)));
      } on http.ClientException {
        if (attempt >= maxRetries) {
          throw const OverpassException(
            OverpassFailure.unavailable,
            'Could not connect to OpenStreetMap infrastructure. The basemap and hazards still work.',
          );
        }
        await Future<void>.delayed(Duration(milliseconds: 300 * (attempt + 1)));
      } on _RetryableOverpassException catch (error) {
        if (attempt >= maxRetries) {
          throw OverpassException(error.failure, error.message);
        }
        await Future<void>.delayed(Duration(milliseconds: 300 * (attempt + 1)));
      }
    }
  }

  Future<List<OsmMapFeature>> _requestChunk(
    GeoBounds bounds,
    Uri requestEndpoint,
  ) async {
    final response = await _client
        .post(
          requestEndpoint,
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
      throw const _RetryableOverpassException(
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
      return features;
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

  List<GeoBounds> _split(GeoBounds bounds) {
    if (bounds.latitudeSpan == 0 || bounds.longitudeSpan == 0) return [bounds];
    final latitudeStep = bounds.latitudeSpan / chunkRows;
    final longitudeStep = bounds.longitudeSpan / chunkColumns;
    return [
      for (var row = 0; row < chunkRows; row++)
        for (var column = 0; column < chunkColumns; column++)
          GeoBounds(
            south: bounds.south + latitudeStep * row,
            west: bounds.west + longitudeStep * column,
            north: row == chunkRows - 1
                ? bounds.north
                : bounds.south + latitudeStep * (row + 1),
            east: column == chunkColumns - 1
                ? bounds.east
                : bounds.west + longitudeStep * (column + 1),
          ),
    ];
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

class _RetryableOverpassException extends OverpassException {
  const _RetryableOverpassException(super.failure, super.message);
}

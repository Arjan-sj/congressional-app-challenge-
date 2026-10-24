import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/geo_bounds.dart';
import '../models/hazard_report.dart';
import '../models/map_layer.dart';
import '../models/osm_infrastructure.dart';
import '../models/school.dart';
import 'hazard_codec.dart';

typedef MapRpc = Future<dynamic> Function(
  String name,
  Map<String, dynamic> params,
);

enum MapFailure {
  timeout,
  connectionOrCors,
  rateLimited,
  server,
  invalidResponse,
  configuration,
  unavailable,
}

class MapDataException implements Exception {
  const MapDataException(
    this.failure,
    this.message, {
    this.retryAfter = const Duration(seconds: 30),
  });
  final MapFailure failure;
  final String message;
  final Duration retryAfter;
}

class MapDataset {
  const MapDataset(
    this.items, {
    this.total = 0,
    this.clustered = false,
    this.features = const [],
  });
  final List<Map<String, dynamic>> items;
  final int total;
  final bool clustered;
  final List<OsmMapFeature> features;
  static const empty = MapDataset([]);
}

class MapSourceState extends ChangeNotifier {
  MapDataset data = MapDataset.empty;
  bool hasData = false;
  bool loading = false;
  String? error;
  MapFailure? failure;
  GeoBounds? bounds;
  void changed() => notifyListeners();
}

class _CacheEntry {
  _CacheEntry(this.bounds, this.key, this.data, this.time);
  final GeoBounds bounds;
  final String key;
  final MapDataset data;
  final DateTime time;
}

/// Central scheduler: one running + one latest viewport per source, no pan backlog.
/// Each layer publishes independently and retains its successful data on errors.
class MapDataService {
  MapDataService({
    required this.rpc,
    this.debounce = const Duration(milliseconds: 300),
    Future<dynamic> Function(Map<String, dynamic>)? infrastructureFallback,
    DateTime Function()? now,
  }) : _fallback = infrastructureFallback,
       _now = now ?? DateTime.now;

  factory MapDataService.supabase(SupabaseClient client) => MapDataService(
    rpc: (name, params) => client.rpc(name, params: params),
    infrastructureFallback: (params) async => (await client.functions.invoke(
      'map-infrastructure',
      body: params,
    )).data,
  );

  final MapRpc rpc;
  final Future<dynamic> Function(Map<String, dynamic>)? _fallback;
  final DateTime Function() _now;
  final Duration debounce;
  final schools = MapSourceState();
  final hazards = MapSourceState();
  final infrastructure = MapSourceState();
  final List<_CacheEntry> _cache = [];
  final Set<String> _running = {};
  final Map<String, DateTime> _cooldown = {};
  final Stopwatch _startup = Stopwatch()..start();
  final List<String> recentErrors = [];
  final Map<String, int> durationsMs = {};
  GeoBounds? bounds;
  double zoom = 15;
  Set<MapLayer> visible = MapLayer.values.toSet();
  String? schoolKind;
  String? hazardKind;
  int _generation = 0;
  int _hazardEpoch = 0;
  bool _disposed = false;
  Timer? _timer;
  int completed = 0,
      cacheHits = 0,
      lookups = 0,
      responseBytes = 0,
      parsingMicros = 0;
  int get active => _running.length;
  final Map<String, int> firstDataMs = {};
  MapSourceState _state(String source) => switch (source) {
    'schools' => schools,
    'hazards' => hazards,
    _ => infrastructure,
  };

  void viewport(GeoBounds next, double nextZoom, Set<MapLayer> layers) {
    bounds = next;
    zoom = nextZoom;
    visible = Set.of(layers);
    _generation++; // Invalidate immediately, including while the debounce runs.
    _timer?.cancel();
    _timer = Timer(debounce, () {
      _load('schools');
      _load('hazards');
      // Optional data gets a later event-loop turn, never gates primary layers.
      scheduleMicrotask(() => _load('infrastructure'));
    });
  }

  Set<String> get categories => {
    if (visible.contains(MapLayer.crossings)) 'crossing',
    if (visible.contains(MapLayer.sidewalks)) 'sidewalk',
    if (visible.contains(MapLayer.walkingPaths) && zoom > 16) 'walkingPath',
    if (visible.contains(MapLayer.bikePaths)) 'bikePath',
    if (visible.contains(MapLayer.bikeLanes)) 'bikeLane',
  };
  bool _enabled(String source) => switch (source) {
    'schools' => visible.contains(MapLayer.schools),
    'hazards' => visible.contains(MapLayer.hazards),
    _ =>
      zoom >= 15 &&
          categories.isNotEmpty &&
          bounds!.latitudeSpan < .12 &&
          bounds!.longitudeSpan < .17 &&
          !bounds!.crossesAntimeridian,
  };
  String _key(String source) =>
      '$source:v1:${source == 'infrastructure' ? (categories.toList()..sort()).join(',') : ''}:'
      '${source == 'schools' ? schoolKind : ''}:${zoom < 13
          ? 'clusters'
          : source == 'infrastructure' && zoom > 16
          ? 'full'
          : 'detail'}:'
      '${source == 'hazards' ? '$_hazardEpoch:$hazardKind' : 0}';

  Future<void> _load(String source, {bool force = false}) async {
    if (_disposed ||
        bounds == null ||
        !_enabled(source) ||
        _running.contains(source) ||
        _running.length >= 2) {
      return;
    }
    final requestBounds = bounds!;
    final key = _key(source);
    final version = _generation;
    final state = _state(source);
    final ttl = source == 'hazards'
        ? const Duration(seconds: 30)
        : const Duration(hours: 24);
    lookups++;
    if (!force) {
      for (final cached in _cache.reversed) {
        if (cached.key == key &&
            cached.bounds.containsBounds(requestBounds) &&
            _now().difference(cached.time) < ttl) {
          cacheHits++;
          state.bounds = cached.bounds;
          state.hasData = true;
          state.data = cached.data;
          state.loading = false;
          state.error = null;
          state.failure = null;
          state.changed();
          return;
        }
      }
    }
    if (_cooldown[source]?.isAfter(_now()) == true) return;
    _running.add(source);
    state.loading = true;
    state.error = null;
    state.failure = null;
    state.changed();
    final watch = Stopwatch()..start();
    // Modest geographic buffer only; no raster tile prefetching.
    final queryBounds = requestBounds.expanded(.15);
    final params = {...queryBounds.rpcParams, 'zoom': zoom};
    if (source == 'schools') params['school_kind'] = schoolKind;
    if (source == 'hazards') params['hazard_kind'] = hazardKind;
    if (source == 'infrastructure') params['categories'] = categories.toList();
    try {
      final data = await _fetch(source, params);
      if (_disposed) return;
      _cache.add(_CacheEntry(queryBounds, key, data, _now()));
      if (_cache.length > 96) _cache.removeAt(0);
      if (version == _generation) {
        state.bounds = queryBounds;
        state.hasData = true;
        state.data = data;
        firstDataMs.putIfAbsent(source, () => _startup.elapsedMilliseconds);
      }
    } catch (error) {
      if (_disposed) return;
      // Browser networking cannot distinguish CORS from a disconnected socket.
      final failure = error is MapDataException
          ? error.failure
          : error is TimeoutException
          ? MapFailure.timeout
          : error is http.ClientException
          ? MapFailure.connectionOrCors
          : error is FormatException || error is TypeError
          ? MapFailure.invalidResponse
          : error is PostgrestException && error.code == '429'
          ? MapFailure.rateLimited
          : error is PostgrestException &&
                const {'PGRST202', '42883', '42P01'}.contains(error.code)
          ? MapFailure.configuration
          : error is PostgrestException &&
                const {'500', '502', '503', '504'}.contains(error.code)
          ? MapFailure.server
          : MapFailure.unavailable;
      final detail = switch (failure) {
        MapFailure.timeout => 'timed out',
        MapFailure.connectionOrCors => 'connection failed (network or CORS)',
        MapFailure.rateLimited => 'rate limited; wait before retrying',
        MapFailure.invalidResponse => 'returned invalid data',
        MapFailure.configuration => 'requires database setup',
        MapFailure.server => 'server temporarily unavailable',
        MapFailure.unavailable => 'temporarily unavailable',
      };
      final message = '$source $detail.';
      recentErrors.add(message);
      if (recentErrors.length > 5) recentErrors.removeAt(0);
      _cooldown[source] = _now().add(
        error is MapDataException
            ? error.retryAfter
            : failure == MapFailure.rateLimited
            ? const Duration(seconds: 60)
            : const Duration(seconds: 30),
      );
      if (version == _generation) {
        state.error = message;
        state.failure = failure;
      }
    } finally {
      _running.remove(source);
      durationsMs[source] = watch.elapsedMilliseconds;
      if (!_disposed) {
        state.loading = false;
        state.changed();
        _load('schools');
        _load('hazards');
        _load('infrastructure');
      }
    }
  }

  Future<dynamic> _call(String name, Map<String, dynamic> params) async {
    // Idempotent reads: one bounded retry for transient server/transport errors.
    for (var attempt = 0; ; attempt++) {
      try {
        final value = await rpc(
          name,
          params,
        ).timeout(const Duration(seconds: 18));
        completed++;
        if (kDebugMode) responseBytes += utf8.encode(jsonEncode(value)).length;
        return value;
      } catch (error) {
        completed++;
        final retryable =
            error is TimeoutException ||
            error is http.ClientException ||
            error is PostgrestException &&
                const {
                  '500',
                  '502',
                  '503',
                  '504',
                  'PGRST000',
                  'PGRST001',
                  'PGRST002',
                }.contains(error.code);
        if (!retryable || attempt >= 1) rethrow;
        await Future<void>.delayed(
          Duration(milliseconds: 400 + _now().millisecond),
        );
      }
    }
  }

  Future<MapDataset> _fetch(String source, Map<String, dynamic> params) async {
    final items = <Map<String, dynamic>>[];
    bool clustered = false;
    int total = 0;
    while (true) {
      final raw = await _call('${source}_in_view', params);
      final parsing = Stopwatch()..start();
      final rows = source == 'infrastructure'
          ? raw as List
          : (raw as Map)['items'] as List;
      items.addAll(rows.map((row) => Map<String, dynamic>.from(row as Map)));
      if (source != 'infrastructure') {
        clustered = raw['clustered'] == true;
        total =
            (raw['total'] as num?)?.toInt() ??
            (clustered
                ? items.fold<int>(
                    0,
                    (sum, r) => sum + (r['count'] as num).toInt(),
                  )
                : items.length);
      }
      parsingMicros += parsing.elapsedMicroseconds;
      if (source == 'schools' || clustered || rows.length < 500) break;
      params['after_id'] = items.last['id'];
    }
    if (source == 'infrastructure' && items.isEmpty && _fallback != null) {
      final raw = await _fallback(params).timeout(const Duration(seconds: 25));
      completed++;
      if (kDebugMode) responseBytes += utf8.encode(jsonEncode(raw)).length;
      if (raw is! Map || raw['items'] is! List) {
        throw const FormatException('Invalid infrastructure response');
      }
      items.addAll(
        (raw['items'] as List).map(
          (row) => Map<String, dynamic>.from(row as Map),
        ),
      );
      if (raw['warning'] != null) {
        throw MapDataException(
          MapFailure.values
                  .where((f) => f.name == raw['failure'])
                  .firstOrNull ??
              MapFailure.unavailable,
          raw['warning'].toString(),
          retryAfter: Duration(
            seconds: (raw['retry_after'] as num?)?.toInt() ?? 60,
          ),
        );
      }
    }
    final dataset = MapDataset(
      List.unmodifiable(items),
      total: total,
      clustered: clustered,
    );
    if (source == 'infrastructure') {
      return MapDataset(
        dataset.items,
        total: items.length,
        features: List.unmodifiable(infrastructureFeatures(dataset)),
      );
    }
    return dataset;
  }

  void invalidateHazards({bool clear = false}) {
    _hazardEpoch++;
    _generation++;
    _cache.removeWhere((entry) => entry.key.startsWith('hazards:'));
    _cooldown.remove('hazards');
    if (clear) {
      hazards.hasData = false;
      hazards.data = MapDataset.empty;
      hazards.changed();
    }
    _load('hazards');
  }

  Future<GeoBounds?> stateBounds(String state) async {
    final row = await _call('school_state_bounds', {'state_code': state});
    return row['south'] == null
        ? null
        : GeoBounds(
            south: (row['south'] as num).toDouble(),
            west: (row['west'] as num).toDouble(),
            north: (row['north'] as num).toDouble(),
            east: (row['east'] as num).toDouble(),
          );
  }

  Future<List<School>> schoolMembers(GeoBounds bounds, String? after) async =>
      (await _call('school_members_in_view', {
            ...bounds.rpcParams,
            'after_id': after ?? '',
            'school_kind': schoolKind,
          }) as List)
          .map((row) => schoolFromRow(Map<String, dynamic>.from(row)))
          .toList();

  Future<List<HazardReport>> hazardsForRoute(
    LatLng origin,
    LatLng destination,
  ) async {
    final south =
        (origin.latitude < destination.latitude
            ? origin.latitude
            : destination.latitude) -
        .019;
    final north =
        (origin.latitude > destination.latitude
            ? origin.latitude
            : destination.latitude) +
        .019;
    final longitudePadding =
        2000 /
        (111320 *
            math.max(
              .01,
              math
                  .cos(
                    (origin.latitude + destination.latitude) /
                        2 *
                        math.pi /
                        180,
                  )
                  .abs(),
            ));
    final west =
        (origin.longitude < destination.longitude
            ? origin.longitude
            : destination.longitude) -
        longitudePadding;
    final east =
        (origin.longitude > destination.longitude
            ? origin.longitude
            : destination.longitude) +
        longitudePadding;
    final data = await _fetch('hazards', {
      'min_lat': south.clamp(-90, 90),
      'max_lat': north.clamp(-90, 90),
      'min_lon': west.clamp(-180, 180),
      'max_lon': east.clamp(-180, 180),
      'zoom': 15,
      'hazard_kind': null,
    });
    return data.items.map(HazardCodec.fromRow).toList();
  }

  void retry(String source) {
    if (_state(source).failure == MapFailure.rateLimited &&
        _cooldown[source]?.isAfter(_now()) == true) {
      return;
    }
    _cooldown.remove(source);
    _load(source, force: true);
  }

  Future<List<School>> search(String text, String? state) async =>
      (await _call('search_schools', {'search_text': text, 'state_code': state})
              as List)
          .map((row) => schoolFromRow(Map<String, dynamic>.from(row)))
          .toList();

  static School schoolFromRow(Map<String, dynamic> row) => School(
    id: row['id'] as String,
    name: row['name'] as String,
    district: row['district'] as String? ?? 'District unavailable',
    districtId: schoolDistrictIdFromRow(row),
    address: row['address'] as String? ?? '',
    city: row['city'] as String? ?? '',
    state: row['state'] as String? ?? '',
    zipCode: row['zip_code'] as String? ?? '',
    latitude: (row['latitude'] as num).toDouble(),
    longitude: (row['longitude'] as num).toDouble(),
    levels: const {},
    classification: row['classification'] as String? ?? 'public',
    sourceYear: row['source_year'] as String?,
  );
  List<HazardReport> get detailedHazards => hazards.data.clustered
      ? []
      : hazards.data.items.map(HazardCodec.fromRow).toList();

  static List<OsmMapFeature> infrastructureFeatures(MapDataset dataset) {
    final result = <OsmMapFeature>[];
    void append(Map<String, dynamic> row, Map geometry, String suffix) {
      final type = geometry['type'];
      if (type == 'GeometryCollection') {
        for (final (index, part) in (geometry['geometries'] as List).indexed) {
          append(row, part as Map, '$suffix:$index');
        }
        return;
      }
      if (!const {
        'Point',
        'LineString',
        'MultiLineString',
        'MultiPoint',
      }.contains(type)) {
        throw const FormatException('Unsupported infrastructure geometry');
      }
      final coordinates = geometry['coordinates'] as List;
      final parts = type == 'MultiLineString' || type == 'MultiPoint'
          ? coordinates
          : [coordinates];
      for (final (index, part) in parts.indexed) {
        final pairs = type == 'Point' || type == 'MultiPoint'
            ? [part]
            : part as List;
        final points = pairs
            .map(
              (pair) => LatLng(
                (pair[1] as num).toDouble(),
                (pair[0] as num).toDouble(),
              ),
            )
            .toList();
        if (points.isEmpty) continue;
        result.add(
          OsmMapFeature(
            id: '${row['id']}$suffix:$index',
            type: InfrastructureType.values.byName(row['category'] as String),
            points: points,
            tags: (row['tags'] as Map? ?? {}).map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            ),
          ),
        );
      }
    }

    for (final row in dataset.items) {
      append(row, row['geometry'] as Map, '');
    }
    return result;
  }

  String get diagnostics =>
      'z ${zoom.toStringAsFixed(1)} • $bounds\n'
      'Schools ${schools.data.total} / ${schools.data.items.length} markers • '
      'Hazards ${hazards.data.total} / ${hazards.data.items.length} markers • Infrastructure ${infrastructure.data.items.length}\n'
      '$active active • $completed completed • $responseBytes decoded JSON bytes • '
      '${lookups == 0 ? 0 : (100 * cacheHits / lookups).round()}% cache hits\n'
      'Request ms $durationsMs • parse $parsingMicros µs • first data ms $firstDataMs\n'
      'Schools ${schools.loading ? 'loading' : schools.error ?? 'ready'} • '
      'Hazards ${hazards.loading ? 'loading' : hazards.error ?? 'ready'} • '
      'Infrastructure ${infrastructure.loading ? 'loading' : infrastructure.error ?? 'ready'}\n'
      '${recentErrors.join('\n')}';

  void markMapReady() {
    firstDataMs.putIfAbsent('map', () => _startup.elapsedMilliseconds);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    schools.dispose();
    hazards.dispose();
    infrastructure.dispose();
  }
}

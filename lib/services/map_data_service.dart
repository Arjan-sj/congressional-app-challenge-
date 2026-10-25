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
import '../models/infrastructure_availability.dart';
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
    this.coverage = InfrastructureCoverage.unknown,
    this.fetchedAt,
    this.expiresAt,
  });
  final List<Map<String, dynamic>> items;
  final int total;
  final bool clustered;
  final List<OsmMapFeature> features;
  final InfrastructureCoverage coverage;
  final DateTime? fetchedAt;
  final DateTime? expiresAt;
  static const empty = MapDataset([]);
}

class MapSourceState extends ChangeNotifier {
  MapDataset data = MapDataset.empty;
  bool hasData = false;
  bool loading = false;
  String? error;
  MapFailure? failure;
  GeoBounds? bounds;
  DateTime? fetchedAt;
  InfrastructureStatus infrastructureStatus = const InfrastructureStatus();
  void changed() => notifyListeners();
}

class _CacheEntry {
  _CacheEntry(
    this.bounds,
    this.key,
    this.data,
    this.time, {
    this.categories = const {},
  });
  final GeoBounds bounds;
  final String key;
  final MapDataset data;
  final DateTime time;
  final Set<String> categories;
}

/// Central scheduler: one running + one latest viewport per source, no pan backlog.
/// Each layer publishes independently and retains its successful data on errors.
class MapDataService {
  MapDataService({
    required this.rpc,
    this.debounce = const Duration(milliseconds: 300),
    Future<dynamic> Function(Map<String, dynamic>)? infrastructureFallback,
    DateTime Function()? now,
    this.rpcTimeout = const Duration(seconds: 18),
    this.fallbackTimeout = const Duration(seconds: 25),
    this.requireInfrastructureCoverage = false,
  }) : _fallback = infrastructureFallback,
       _now = now ?? DateTime.now;

  factory MapDataService.supabase(SupabaseClient client) => MapDataService(
    rpc: (name, params) => client.rpc(
      name == 'infrastructure_in_view' ? 'infrastructure_viewport' : name,
      params: params,
    ),
    requireInfrastructureCoverage: true,
    infrastructureFallback: (params) async => (await client.functions.invoke(
      'map-infrastructure',
      body: params,
    )).data,
  );

  final MapRpc rpc;
  final Future<dynamic> Function(Map<String, dynamic>)? _fallback;
  final DateTime Function() _now;
  final Duration debounce;
  final Duration rpcTimeout;
  final Duration fallbackTimeout;
  final bool requireInfrastructureCoverage;
  final schools = MapSourceState();
  final hazards = MapSourceState();
  final infrastructure = MapSourceState();
  final List<_CacheEntry> _cache = [];
  final Set<String> _running = {};
  final Map<String, DateTime> _cooldown = {};
  final Map<String, MapFailure> _cooldownFailure = {};
  GeoBounds? _infrastructureRequestBounds;
  String? _infrastructureRequestKey;
  bool _infrastructureFailed = false;
  Timer? _infrastructureCooldownTimer;
  Timer? _infrastructureExpiryTimer;
  DateTime? _infrastructureExpiresAt;
  final Set<String> _failedInfrastructureScopes = {};
  bool _infrastructureRecoveryProbe = false;
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
    if (_disposed) return;
    bounds = next;
    zoom = nextZoom;
    visible = Set.of(layers);
    _generation++; // Invalidate immediately, including while the debounce runs.
    _reconcileInfrastructure();
    _timer?.cancel();
    _timer = Timer(debounce, () {
      _drain();
    });
  }

  Set<String> get categories => {
    if (_infrastructureRecoveryProbe || visible.contains(MapLayer.crossings))
      'crossing',
    if (_infrastructureRecoveryProbe || visible.contains(MapLayer.sidewalks))
      'sidewalk',
    if ((_infrastructureRecoveryProbe ||
            visible.contains(MapLayer.walkingPaths)) &&
        zoom > 16)
      'walkingPath',
    if (_infrastructureRecoveryProbe || visible.contains(MapLayer.bikePaths))
      'bikePath',
    if (_infrastructureRecoveryProbe || visible.contains(MapLayer.bikeLanes))
      'bikeLane',
  };

  bool get infrastructureRequestEligible =>
      bounds != null && _enabled('infrastructure');
  bool get infrastructureViewportEligible =>
      bounds != null &&
      zoom >= 15 &&
      bounds!.expanded(.15).latitudeSpan <= .08 &&
      bounds!.expanded(.15).longitudeSpan <= .08 &&
      !bounds!.crossesAntimeridian;

  _CacheEntry? _cached(String source) {
    final currentBounds = bounds;
    if (currentBounds == null) return null;
    final key = _key(source);
    final ttl = source == 'hazards'
        ? const Duration(seconds: 30)
        : const Duration(hours: 24);
    for (final entry in _cache.reversed) {
      final matches =
          entry.key == key ||
          source == 'infrastructure' &&
              categories.every(entry.categories.contains) &&
              (entry.key.contains(':full:') || !key.contains(':full:'));
      if (matches &&
          entry.bounds.containsBounds(currentBounds) &&
          _now().difference(entry.time) < ttl &&
          (entry.data.expiresAt == null ||
              entry.data.expiresAt!.isAfter(_now()))) {
        return entry;
      }
    }
    return null;
  }

  void _reconcileInfrastructure({bool networkSuccess = false}) {
    if (_disposed) return;
    final previousData = infrastructure.data;
    final previousBounds = infrastructure.bounds;
    final previousStatus = infrastructure.infrastructureStatus;
    final cached = infrastructureRequestEligible
        ? _cached('infrastructure')
        : null;
    if (cached != null) {
      final ttlEnd = cached.time.add(const Duration(hours: 24));
      final expiry =
          cached.data.expiresAt != null &&
              cached.data.expiresAt!.isBefore(ttlEnd)
          ? cached.data.expiresAt!
          : ttlEnd;
      if (_infrastructureExpiresAt != expiry) {
        _infrastructureExpiryTimer?.cancel();
        _infrastructureExpiresAt = expiry;
        _infrastructureExpiryTimer = Timer(expiry.difference(_now()), () {
          _infrastructureExpiresAt = null;
          if (!_disposed) {
            _reconcileInfrastructure();
            _drain();
          }
        });
      }
    } else {
      _infrastructureExpiryTimer?.cancel();
      _infrastructureExpiresAt = null;
    }
    if (cached != null) {
      infrastructure.data = cached.data;
      infrastructure.bounds = cached.bounds;
      infrastructure.fetchedAt = cached.data.fetchedAt ?? cached.time;
      infrastructure.hasData = true;
    } else {
      // Never relabel features from the preceding viewport as current data.
      infrastructure.data = MapDataset.empty;
      infrastructure.bounds = null;
      infrastructure.fetchedAt = null;
      infrastructure.hasData = false;
    }
    final loading =
        _running.contains('infrastructure') &&
        _infrastructureRequestKey == _key('infrastructure') &&
        bounds != null &&
        _infrastructureRequestBounds?.containsBounds(bounds!) == true &&
        infrastructureRequestEligible;
    infrastructure.loading = loading;
    final retryAt = _cooldown['infrastructure'];
    infrastructure.infrastructureStatus = InfrastructureStatus(
      availability: loading
          ? InfrastructureAvailability.loading
          : cached != null
          ? networkSuccess
                ? cached.data.features.isEmpty
                      ? InfrastructureAvailability.empty
                      : InfrastructureAvailability.available
                : InfrastructureAvailability.cached
          : _infrastructureFailed
          ? InfrastructureAvailability.unavailable
          : InfrastructureAvailability.notRequested,
      coverage:
          cached?.data.coverage ??
          (_infrastructureFailed
              ? InfrastructureCoverage.unavailable
              : InfrastructureCoverage.unknown),
      hasValidCache: cached != null,
      isEmpty: cached?.data.features.isEmpty == true,
      lastAttemptFailed: _infrastructureFailed,
      retryAt: retryAt?.isAfter(_now()) == true ? retryAt : null,
    );
    final currentStatus = infrastructure.infrastructureStatus;
    if (!identical(previousData, infrastructure.data) ||
        !identical(previousBounds, infrastructure.bounds) ||
        previousStatus.availability != currentStatus.availability ||
        previousStatus.coverage != currentStatus.coverage ||
        previousStatus.hasValidCache != currentStatus.hasValidCache ||
        previousStatus.lastAttemptFailed != currentStatus.lastAttemptFailed ||
        previousStatus.retryAt != currentStatus.retryAt ||
        previousStatus.isEmpty != currentStatus.isEmpty) {
      infrastructure.changed();
    }
  }

  void _drain() {
    if (_disposed || _timer?.isActive == true) return;
    _load('schools');
    _load('hazards');
    // Optional work cannot occupy both primary-layer slots.
    _load('infrastructure');
  }

  bool _enabled(String source) => switch (source) {
    'schools' => visible.contains(MapLayer.schools),
    'hazards' => visible.contains(MapLayer.hazards),
    _ => infrastructureViewportEligible && categories.isNotEmpty,
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
        (source == 'infrastructure'
            ? _running.length >= 2
            : _running.where((s) => s != 'infrastructure').length >= 2)) {
      return;
    }
    final requestBounds = bounds!;
    final key = _key(source);
    final scope = '$key:${requestBounds.toString()}';
    final version = _generation;
    final state = _state(source);
    lookups++;
    if (!force) {
      final cached = _cached(source);
      if (cached != null) {
        cacheHits++;
        if (source == 'infrastructure' &&
            identical(state.data, cached.data) &&
            state.hasData &&
            !state.loading) {
          return;
        }
        state.bounds = cached.bounds;
        state.hasData = true;
        state.data = cached.data;
        state.loading = false;
        state.error = null;
        state.failure = null;
        if (source == 'infrastructure') {
          _reconcileInfrastructure();
        } else {
          state.changed();
        }
        return;
      }
    }
    if (source == 'infrastructure' &&
        !force &&
        _failedInfrastructureScopes.contains(scope)) {
      return;
    }
    if (_cooldown[source]?.isAfter(_now()) == true) return;
    _running.add(source);
    if (source == 'infrastructure') {
      _infrastructureRequestBounds = requestBounds;
      _infrastructureRequestKey = key;
    }
    state.loading = true;
    state.error = null;
    state.failure = null;
    if (source == 'infrastructure') {
      _reconcileInfrastructure();
    } else {
      state.changed();
    }
    final watch = Stopwatch()..start();
    // Modest geographic buffer only; no raster tile prefetching.
    final queryBounds = requestBounds.expanded(.15);
    final params = {...queryBounds.rpcParams, 'zoom': zoom};
    if (source == 'schools') params['school_kind'] = schoolKind;
    if (source == 'hazards') params['hazard_kind'] = hazardKind;
    if (source == 'infrastructure') params['categories'] = categories.toList();
    try {
      final data = await _fetch(
        source,
        params,
        isCurrent: () => version == _generation && !_disposed,
      );
      if (_disposed) return;
      _cache.add(
        _CacheEntry(
          queryBounds,
          key,
          data,
          _now(),
          categories: source == 'infrastructure'
              ? Set<String>.from(params['categories'] as List)
              : const {},
        ),
      );
      if (_cache.length > 96) _cache.removeAt(0);
      if (version == _generation) {
        state.bounds = queryBounds;
        state.hasData = true;
        state.data = data;
        state.fetchedAt = data.fetchedAt ?? _now();
        _cooldown.remove(source);
        _cooldownFailure.remove(source);
        if (source == 'infrastructure') {
          _infrastructureFailed = false;
          _failedInfrastructureScopes.remove(scope);
        }
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
          : error is PostgrestException && error.code == '429' ||
                error is FunctionException && error.status == 429
          ? MapFailure.rateLimited
          : error is PostgrestException &&
                const {'PGRST202', '42883', '42P01'}.contains(error.code)
          ? MapFailure.configuration
          : error is FunctionException &&
                const {401, 403, 404}.contains(error.status)
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
      final delay = error is MapDataException
          ? error.retryAfter
          : failure == MapFailure.rateLimited
          ? const Duration(seconds: 60)
          : const Duration(seconds: 30);
      // Stale transport failures do not block an unrelated new viewport.
      if (version == _generation || failure == MapFailure.rateLimited) {
        _cooldown[source] = _now().add(
          Duration(milliseconds: delay.inMilliseconds.clamp(1000, 3600000)),
        );
        _cooldownFailure[source] = failure;
      }
      if (version == _generation) {
        state.error = message;
        state.failure = failure;
        if (source == 'infrastructure') {
          _infrastructureFailed = true;
          _failedInfrastructureScopes.add(scope);
          if (_failedInfrastructureScopes.length > 64) {
            _failedInfrastructureScopes.remove(
              _failedInfrastructureScopes.first,
            );
          }
        }
      }
      if (source == 'infrastructure' && _cooldown[source] != null) {
        if (failure == MapFailure.rateLimited) {
          _infrastructureFailed = true;
          state.error = message;
          state.failure = failure;
        }
        _infrastructureCooldownTimer?.cancel();
        _infrastructureCooldownTimer = Timer(
          _cooldown[source]!.difference(_now()),
          () {
            if (!_disposed) _reconcileInfrastructure(); // Enable retry, no automatic retry loop.
          },
        );
      }
    } finally {
      _running.remove(source);
      if (source == 'infrastructure') _infrastructureRecoveryProbe = false;
      durationsMs[source] = watch.elapsedMilliseconds;
      if (!_disposed) {
        state.loading = false;
        if (source == 'infrastructure') {
          _reconcileInfrastructure(
            networkSuccess: version == _generation && !_infrastructureFailed,
          );
        } else {
          state.changed();
        }
        _drain();
      }
    }
  }

  Future<dynamic> _call(
    String name,
    Map<String, dynamic> params, {
    bool Function()? isCurrent,
  }) async {
    // Idempotent reads: one bounded retry for transient server/transport errors.
    for (var attempt = 0; ; attempt++) {
      try {
        final value = await rpc(name, params).timeout(rpcTimeout);
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
        if (!retryable ||
            attempt >= 1 ||
            isCurrent?.call() == false ||
            _disposed) {
          rethrow;
        }
        await Future<void>.delayed(
          Duration(milliseconds: 400 + _now().millisecond),
        );
        if (isCurrent?.call() == false || _disposed) rethrow;
      }
    }
  }

  Future<MapDataset> _fetch(
    String source,
    Map<String, dynamic> params, {
    bool Function()? isCurrent,
  }) async {
    final items = <Map<String, dynamic>>[];
    bool clustered = false;
    int total = 0;
    bool infrastructureTruncated = false;
    bool fallbackRequired = !requireInfrastructureCoverage;
    InfrastructureCoverage importedCoverage = InfrastructureCoverage.unknown;
    DateTime? importExpiresAt;
    while (true) {
      if (isCurrent?.call() == false || _disposed) {
        throw const MapDataException(
          MapFailure.unavailable,
          'Viewport changed',
        );
      }
      final raw = await _call(
        '${source}_in_view',
        params,
        isCurrent: isCurrent,
      );
      final parsing = Stopwatch()..start();
      if (source == 'infrastructure' && raw is Map) {
        if (raw['fallback_required'] is! bool ||
            !{
              'complete',
              'partial',
              'missing',
              'stale',
            }.contains(raw['import_coverage'])) {
          throw const FormatException(
            'Invalid infrastructure coverage metadata',
          );
        }
        fallbackRequired =
            raw['fallback_required'] == true &&
            raw['import_coverage'] != 'complete';
        importedCoverage =
            InfrastructureCoverage.values
                .where((value) => value.name == raw['coverage'])
                .firstOrNull ??
            InfrastructureCoverage.unknown;
        importExpiresAt = DateTime.tryParse(
          raw['expires_at']?.toString() ?? '',
        );
        if (importExpiresAt == null || !importExpiresAt.isAfter(_now())) {
          throw const FormatException(
            'Expired infrastructure coverage metadata',
          );
        }
      } else if (source == 'infrastructure' && requireInfrastructureCoverage) {
        throw const FormatException(
          'Infrastructure coverage migration is required',
        );
      }
      final rows = source == 'infrastructure'
          ? (raw is Map ? raw['items'] as List : raw as List)
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
      if (source == 'infrastructure' && items.length >= 5000) {
        infrastructureTruncated = true;
        break;
      }
      if (items.last['id'] is! String ||
          params['after_id'] == items.last['id']) {
        throw const FormatException('Map pagination did not advance');
      }
      params['after_id'] = items.last['id'];
    }
    InfrastructureCoverage coverage = infrastructureTruncated
        ? InfrastructureCoverage.partial
        : importedCoverage;
    DateTime? fetchedAt;
    DateTime? expiresAt = importExpiresAt;
    if (source == 'infrastructure' &&
        items.isEmpty &&
        fallbackRequired &&
        _fallback != null) {
      if (isCurrent?.call() == false || _disposed) {
        throw const MapDataException(
          MapFailure.unavailable,
          'Viewport changed',
        );
      }
      final raw = await _fallback(params).timeout(fallbackTimeout);
      completed++;
      if (kDebugMode) responseBytes += utf8.encode(jsonEncode(raw)).length;
      if (raw is! Map || raw['items'] is! List) {
        throw const FormatException('Invalid infrastructure response');
      }
      items.addAll(
        (raw['items'] as List)
            .take(5000)
            .map((row) => Map<String, dynamic>.from(row as Map)),
      );
      if (raw['warning'] != null || raw['coverage'] == 'unavailable') {
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
      coverage =
          InfrastructureCoverage.values
              .where(
                (c) =>
                    c.name == raw['coverage'] &&
                    c != InfrastructureCoverage.unavailable,
              )
              .firstOrNull ??
          InfrastructureCoverage.unknown;
      if ((raw['items'] as List).length > 5000) {
        coverage = InfrastructureCoverage.partial;
      }
      fetchedAt = DateTime.tryParse(raw['fetched_at']?.toString() ?? '');
      expiresAt =
          DateTime.tryParse(raw['expires_at']?.toString() ?? '') ??
          fetchedAt?.add(const Duration(hours: 24));
      if (fetchedAt != null &&
          (expiresAt == null ||
              expiresAt.isAfter(fetchedAt.add(const Duration(hours: 24))))) {
        expiresAt = fetchedAt.add(const Duration(hours: 24));
      }
      if (raw['fetched_at'] != null && fetchedAt == null ||
          raw['expires_at'] != null &&
              DateTime.tryParse(raw['expires_at'].toString()) == null ||
          fetchedAt?.isAfter(_now().add(const Duration(minutes: 5))) == true ||
          raw['bounds'] != null && raw['bounds'] is! List) {
        throw const FormatException('Invalid infrastructure cache metadata');
      }
      if (raw['bounds'] case final List box) {
        if (box.length != 4 ||
            box.any((v) => v is! num || !v.isFinite) ||
            (box[0] as num) > (box[2] as num) ||
            !GeoBounds(
              south: (box[0] as num).toDouble(),
              west: (box[1] as num).toDouble(),
              north: (box[2] as num).toDouble(),
              east: (box[3] as num).toDouble(),
            ).containsBounds(
              GeoBounds(
                south: params['min_lat'] as double,
                west: params['min_lon'] as double,
                north: params['max_lat'] as double,
                east: params['max_lon'] as double,
              ),
            )) {
          throw const FormatException(
            'Infrastructure cache does not cover the requested area',
          );
        }
      }
      if (expiresAt != null && !expiresAt.isAfter(_now())) {
        throw const MapDataException(
          MapFailure.unavailable,
          'Expired infrastructure cache',
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
        coverage: coverage,
        fetchedAt: fetchedAt,
        expiresAt: expiresAt,
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
    if ((source == 'infrastructure' ||
            _cooldownFailure[source] == MapFailure.rateLimited) &&
        _cooldown[source]?.isAfter(_now()) == true) {
      return;
    }
    _cooldown.remove(source);
    if (source == 'infrastructure') {
      // Recovery can probe availability even if all remembered preferences are
      // off. Hiding controls must never make the Retry action a dead end.
      if (categories.isEmpty) _infrastructureRecoveryProbe = true;
      _reconcileInfrastructure();
    }
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
      // PostGIS viewport clipping can return a valid empty Point/LineString.
      // It contributes no visible geometry and must not fail the entire layer.
      if (coordinates.isEmpty) return;
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
    _infrastructureCooldownTimer?.cancel();
    _infrastructureExpiryTimer?.cancel();
    schools.dispose();
    hazards.dispose();
    infrastructure.dispose();
  }
}

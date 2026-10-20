import 'dart:async';

import 'package:congressional_app/models/geo_bounds.dart';
import 'package:congressional_app/models/map_layer.dart';
import 'package:congressional_app/services/map_data_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:congressional_app/services/map_marker_index.dart';

const area = GeoBounds(south: 42, west: -88.12, north: 42.02, east: -88.10);
const other = GeoBounds(south: 41, west: -87, north: 41.02, east: -86.98);
final primary = {MapLayer.schools, MapLayer.hazards};
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));
Map<String, dynamic> response(String id) => {
  'items': [
    {'id': id},
  ],
  'total': 1,
};

void main() {
  test(
    'infrastructure is decoded once, including clipped multiline collections',
    () async {
      final service = MapDataService(
        debounce: Duration.zero,
        rpc: (name, p) async => [
          {
            'id': 'w1/sidewalk',
            'category': 'sidewalk',
            'geometry': {
              'type': 'GeometryCollection',
              'geometries': [
                {
                  'type': 'MultiLineString',
                  'coordinates': [
                    [
                      [-88.1, 42],
                      [-88.101, 42.001],
                    ],
                    [
                      [-88.102, 42],
                      [-88.103, 42.001],
                    ],
                  ],
                },
              ],
            },
          },
          {
            'id': 'n2/crossing',
            'category': 'crossing',
            'tags': {'crossing:signals': 'yes'},
            'geometry': {
              'type': 'Point',
              'coordinates': [-88.1, 42],
            },
          },
        ],
      );
      addTearDown(service.dispose);
      service.viewport(area, 17, {MapLayer.sidewalks, MapLayer.crossings});
      await settle();
      final features = service.infrastructure.data.features;
      expect(features, hasLength(3));
      expect(features.last.tags['crossing:signals'], 'yes');
      service.viewport(area, 17, {MapLayer.sidewalks, MapLayer.crossings});
      await settle();
      expect(identical(service.infrastructure.data.features, features), isTrue);
    },
  );

  test('malformed optional geometry is rejected before rendering', () async {
    final service = MapDataService(
      debounce: Duration.zero,
      rpc: (name, p) async => name == 'infrastructure_in_view'
          ? [
              {
                'id': 'bad',
                'category': 'sidewalk',
                'geometry': {'type': 'Polygon', 'coordinates': []},
              },
            ]
          : {'items': []},
    );
    addTearDown(service.dispose);
    service.viewport(area, 17, {MapLayer.schools, MapLayer.sidewalks});
    await settle();
    expect(service.infrastructure.failure, MapFailure.invalidResponse);
    expect(service.infrastructure.data.features, isEmpty);
    expect(service.schools.error, isNull);
    expect(service.schools.hasData, isTrue);
  });
  test(
    'rate limits are not retried or bypassed by the retry control',
    () async {
      var calls = 0;
      final service = MapDataService(
        debounce: Duration.zero,
        rpc: (name, p) async {
          calls++;
          throw const PostgrestException(message: 'busy', code: '429');
        },
      );
      addTearDown(service.dispose);
      service.viewport(area, 15, {MapLayer.schools});
      await settle();
      service.retry('schools');
      service.viewport(area, 15, {MapLayer.schools});
      await settle();
      expect(calls, 1);
      expect(service.schools.failure, MapFailure.rateLimited);
    },
  );

  test(
    'marker collision lookup covers co-located and antimeridian schools',
    () {
      final local = MapMarkerIndex([const LatLng(42, -88)], 15);
      expect(local.nearSchool(const LatLng(42, -88)), isTrue);
      expect(local.nearSchool(const LatLng(42, -87)), isFalse);
      final wrapped = MapMarkerIndex([const LatLng(60, 179.999)], 8);
      expect(wrapped.nearSchool(const LatLng(60, -179.999)), isTrue);
    },
  );
  test(
    'schools and hazards start concurrently; optional failure cannot gate them',
    () async {
      final calls = <String>[];
      final school = Completer<dynamic>(), hazard = Completer<dynamic>();
      final service = MapDataService(
        debounce: Duration.zero,
        rpc: (name, p) {
          calls.add(name);
          if (name == 'schools_in_view') return school.future;
          if (name == 'hazards_in_view') return hazard.future;
          return Future.error(StateError('provider offline'));
        },
      );
      addTearDown(service.dispose);
      service.viewport(area, 15, MapLayer.values.toSet());
      await settle();
      expect(calls, ['schools_in_view', 'hazards_in_view']);
      expect(service.active, 2);
      school.complete(response('first-school'));
      await settle();
      expect(service.schools.data.items.single['id'], 'first-school');
      expect(service.hazards.loading, isTrue);
      expect(service.infrastructure.error, isNotNull);
      hazard.complete({'items': []});
      await settle();
      expect(service.schools.error, isNull);
      expect(service.hazards.error, isNull);
    },
  );

  test(
    'overlapping cached region and unrelated layer toggles cause zero requests',
    () async {
      var calls = 0;
      final service = MapDataService(
        debounce: Duration.zero,
        rpc: (name, p) async {
          calls++;
          return name == 'infrastructure_in_view' ? [] : {'items': []};
        },
      );
      addTearDown(service.dispose);
      service.viewport(area, 15, primary);
      await settle();
      expect(calls, 2);
      const overlap = GeoBounds(
        south: 42.001,
        west: -88.119,
        north: 42.021,
        east: -88.099,
      );
      service.viewport(overlap, 15, {...primary, MapLayer.walkingPaths});
      await settle();
      expect(calls, 2); // Walking paths are still hidden until zoom > 16.
      service.viewport(area, 15, {MapLayer.schools});
      await settle();
      expect(calls, 2);
      expect(service.cacheHits, greaterThan(0));
    },
  );

  test(
    'rapid panning debounces and never queues intermediate viewports',
    () async {
      final requested = <double>[];
      final first = Completer<dynamic>();
      final service = MapDataService(
        debounce: Duration.zero,
        rpc: (name, p) {
          requested.add(p['min_lat'] as double);
          return requested.length == 1
              ? first.future
              : Future.value(response('latest'));
        },
      );
      addTearDown(service.dispose);
      service.viewport(area, 15, {MapLayer.schools});
      await settle();
      for (var i = 0; i < 100; i++) {
        service.viewport(other, 15, {MapLayer.schools});
      }
      await settle();
      expect(requested, hasLength(1));
      first.complete(response('obsolete'));
      await settle();
      expect(requested, hasLength(2));
      expect(service.schools.data.items.single['id'], 'latest');
      expect(service.active, 0);
    },
  );

  test('low zoom never fetches infrastructure and accepts complete school clusters', () async {
    final calls = <String>[];
    final service = MapDataService(
      debounce: Duration.zero,
      rpc: (name, p) async {
        calls.add(name);
        return {
          'items': [
            {'id': 'cluster', 'count': 10000},
          ],
          'total': 10000,
          'clustered': true,
        };
      },
    );
    addTearDown(service.dispose);
    service.viewport(
      const GeoBounds(south: 20, west: -170, north: 72, east: -60),
      5,
      MapLayer.values.toSet(),
    );
    await settle();
    expect(calls, ['schools_in_view', 'hazards_in_view']);
    expect(service.schools.data.total, 10000);
    expect(service.schools.data.items, hasLength(1));
    expect(service.schools.data.clustered, isTrue);
  });

  test('hazard freshness and invalidation never refetch schools', () async {
    var now = DateTime.utc(2026);
    final counts = <String, int>{};
    final service = MapDataService(
      debounce: Duration.zero,
      now: () => now,
      rpc: (name, p) async {
        counts.update(name, (n) => n + 1, ifAbsent: () => 1);
        return {'items': []};
      },
    );
    addTearDown(service.dispose);
    service.viewport(area, 15, primary);
    await settle();
    now = now.add(const Duration(seconds: 31));
    service.viewport(area, 15, primary);
    await settle();
    expect(counts['hazards_in_view'], 2);
    expect(counts['schools_in_view'], 1);
    service.invalidateHazards(clear: true);
    expect(service.hazards.data.items, isEmpty);
    await settle();
    expect(counts['hazards_in_view'], 3);
    expect(counts['schools_in_view'], 1);
  });

  test(
    'failed source keeps old data, cools down and supports explicit retry',
    () async {
      var fail = false, calls = 0;
      final service = MapDataService(
        debounce: Duration.zero,
        rpc: (name, p) async {
          calls++;
          if (fail) throw const FormatException('invalid response');
          return response('saved');
        },
      );
      addTearDown(service.dispose);
      service.viewport(area, 15, {MapLayer.schools});
      await settle();
      fail = true;
      service.viewport(other, 15, {MapLayer.schools});
      await settle();
      expect(service.schools.data.items.single['id'], 'saved');
      expect(service.schools.error, isNotNull);
      service.viewport(other, 15, {MapLayer.schools});
      await settle();
      expect(calls, 2);
      fail = false;
      service.retry('schools');
      await settle();
      expect(calls, 3);
      expect(service.schools.error, isNull);
    },
  );

  test(
    'hazard keyset pages exceed Supabase result cap without dropping records',
    () async {
      final after = <String?>[];
      final service = MapDataService(
        debounce: Duration.zero,
        rpc: (name, p) async {
          after.add(p['after_id'] as String?);
          return {
            'items': p['after_id'] == null
                ? List.generate(500, (i) => {'id': '$i'})
                : [
                    {'id': '500'},
                  ],
          };
        },
      );
      addTearDown(service.dispose);
      service.viewport(area, 15, {MapLayer.hazards});
      await settle();
      expect(after, [null, '499']);
      expect(service.hazards.data.items, hasLength(501));
    },
  );

  test('school classification changes only the school request key', () async {
    final calls = <String>[];
    final service = MapDataService(
      debounce: Duration.zero,
      rpc: (name, p) async {
        calls.add(name);
        return {'items': []};
      },
    );
    addTearDown(service.dispose);
    service.viewport(area, 15, primary);
    await settle();
    service.schoolKind = 'private';
    service.viewport(area, 15, primary);
    await settle();
    expect(calls, ['schools_in_view', 'hazards_in_view', 'schools_in_view']);
  });

  test(
    'antimeridian bounds wrap, expand and reuse coverage without inversion',
    () {
      const bounds = GeoBounds(south: 50, west: 170, north: 70, east: -170);
      expect(bounds.longitudeSpan, 20);
      expect(bounds.contains(const LatLng(60, 179)), isTrue);
      expect(bounds.contains(const LatLng(60, -179)), isTrue);
      expect(bounds.contains(const LatLng(60, 0)), isFalse);
      expect(
        bounds.containsBounds(
          const GeoBounds(south: 55, west: 175, north: 65, east: -175),
        ),
        isTrue,
      );
      expect(
        bounds.containsBounds(
          const GeoBounds(south: 55, west: -175, north: 65, east: 175),
        ),
        isFalse,
      );
      expect(bounds.expanded(.1).west, 168);
      expect(bounds.expanded(.1).east, -168);
      expect(bounds.rpcParams['min_lon'], 170);
    },
  );

  test('empty region is cached and disposed requests cannot publish', () async {
    var calls = 0;
    final pending = Completer<dynamic>();
    final service = MapDataService(
      debounce: Duration.zero,
      rpc: (name, p) {
        calls++;
        return pending.future;
      },
    );
    service.viewport(area, 15, {MapLayer.schools});
    await settle();
    service.dispose();
    pending.complete({'items': []});
    await settle();
    expect(calls, 1);
  });
}

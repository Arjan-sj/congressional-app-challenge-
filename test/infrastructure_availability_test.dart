import 'dart:async';

import 'package:congressional_app/models/geo_bounds.dart';
import 'package:congressional_app/models/infrastructure_availability.dart';
import 'package:congressional_app/models/map_layer.dart';
import 'package:congressional_app/services/map_data_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const area = GeoBounds(south: 42, west: -88.12, north: 42.02, east: -88.10);
const other = GeoBounds(south: 41, west: -87, north: 41.02, east: -86.98);
final all = MapLayer.values.toSet();
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 25));
Map<String, dynamic> feature([String id = 'sidewalk']) => {
  'id': id,
  'category': 'sidewalk',
  'geometry': {
    'type': 'LineString',
    'coordinates': [
      [-88.11, 42.01],
      [-88.109, 42.011],
    ],
  },
};
MapRpc infraRpc(Future<dynamic> Function(Map<String, dynamic>) load) =>
    (name, p) async =>
        name == 'infrastructure_in_view' ? await load(p) : {'items': []};
InfrastructureStatus status(MapDataService s) =>
    s.infrastructure.infrastructureStatus;

void main() {
  test('all six states distinguish initial, loading, available, cached, empty and failed', () async {
    final pending = Completer<dynamic>();
    var result = 0;
    final s = MapDataService(
      debounce: Duration.zero,
      rpc: infraRpc((_) async {
        if (result == 0) return pending.future;
        if (result == 1) return [];
        throw StateError('Offline');
      }),
    );
    addTearDown(s.dispose);
    expect(status(s).availability, InfrastructureAvailability.notRequested);
    s.viewport(area, 17, all);
    await settle();
    expect(status(s).availability, InfrastructureAvailability.loading);
    pending.complete([feature()]);
    await settle();
    expect(status(s).availability, InfrastructureAvailability.available);
    expect(status(s).showLayerControls, isTrue);
    s.viewport(area, 17, all);
    await settle();
    expect(status(s).availability, InfrastructureAvailability.cached);
    result = 1;
    s.viewport(other, 17, all);
    await settle();
    expect(status(s).availability, InfrastructureAvailability.empty);
    result = 2;
    s.retry('infrastructure');
    await settle();
    expect(status(s).availability, InfrastructureAvailability.cached);
    expect(status(s).isEmpty, isTrue);
  });
  test('failure hides optional controls without disabling request eligibility, then retry restores them', () async {
    var now = DateTime.utc(2026);
    var fail = true;
    var calls = 0;
    final s = MapDataService(
      debounce: Duration.zero,
      now: () => now,
      rpc: infraRpc((_) async {
        calls++;
        if (fail) throw StateError('Offline');
        return [feature()];
      }),
    );
    addTearDown(s.dispose);
    s.viewport(area, 17, all);
    await settle();
    expect(status(s).availability, InfrastructureAvailability.unavailable);
    expect(status(s).showLayerControls, isFalse);
    expect(s.infrastructureRequestEligible, isTrue);
    expect(s.visible, all);
    for (var i = 0; i < 50; i++) {
      s.retry('infrastructure');
      s.viewport(area, 17, all);
    }
    await settle();
    expect(calls, 1);
    now = now.add(const Duration(seconds: 31));
    fail = false;
    s.retry('infrastructure');
    await settle();
    expect(calls, 2);
    expect(status(s).showLayerControls, isTrue);
    expect(s.infrastructure.data.features, hasLength(1));
  });
  test('valid same-viewport cache survives a failed forced refresh with original provenance', () async {
    var fail = false;
    final s = MapDataService(
      debounce: Duration.zero,
      rpc: infraRpc((_) async {
        if (fail) throw StateError('Offline');
        return [feature()];
      }),
    );
    addTearDown(s.dispose);
    s.viewport(area, 17, all);
    await settle();
    final loaded = s.infrastructure.data;
    final bounds = s.infrastructure.bounds;
    final time = s.infrastructure.fetchedAt;
    fail = true;
    s.retry('infrastructure');
    await settle();
    expect(status(s).availability, InfrastructureAvailability.cached);
    expect(status(s).hasValidCache, isTrue);
    expect(status(s).lastAttemptFailed, isTrue);
    expect(status(s).showLayerControls, isTrue);
    expect(identical(s.infrastructure.data, loaded), isTrue);
    expect(s.infrastructure.bounds, bounds);
    expect(s.infrastructure.fetchedAt, time);
  });
  test('panning immediately clears unrelated features and failure cannot relabel them', () async {
    var fail = false;
    final s = MapDataService(
      debounce: Duration.zero,
      rpc: infraRpc((_) async {
        if (fail) throw StateError('Offline');
        return [feature()];
      }),
    );
    addTearDown(s.dispose);
    s.viewport(area, 17, all);
    await settle();
    fail = true;
    s.viewport(other, 17, all);
    expect(s.infrastructure.data.features, isEmpty);
    expect(s.infrastructure.bounds, isNull);
    await settle();
    expect(status(s).showLayerControls, isFalse);
    expect(status(s).hasValidCache, isFalse);
    s.viewport(area, 17, all);
    await settle();
    expect(status(s).hasValidCache, isTrue);
    expect(status(s).showLayerControls, isTrue);
  });
  test('expired cache is not preserved after a network error', () async {
    var now = DateTime.utc(2026);
    var fail = false;
    final s = MapDataService(
      debounce: Duration.zero,
      now: () => now,
      rpc: infraRpc((_) async {
        if (fail) throw StateError('Offline');
        return [feature()];
      }),
    );
    addTearDown(s.dispose);
    s.viewport(area, 17, all);
    await settle();
    now = now.add(const Duration(hours: 25));
    fail = true;
    s.viewport(area, 17, all);
    await settle();
    expect(status(s).hasValidCache, isFalse);
    expect(status(s).showLayerControls, isFalse);
  });
  test('empty fallback response is successful and cached, with explicit query coverage', () async {
    var calls = 0;
    final s = MapDataService(
      debounce: Duration.zero,
      rpc: infraRpc((_) async => []),
      infrastructureFallback: (_) async {
        calls++;
        return {'items': [], 'coverage': 'complete'};
      },
    );
    addTearDown(s.dispose);
    s.viewport(area, 17, all);
    await settle();
    expect(status(s).availability, InfrastructureAvailability.empty);
    expect(status(s).coverage, InfrastructureCoverage.complete);
    expect(s.infrastructure.error, isNull);
    s.viewport(area, 17, all);
    await settle();
    expect(calls, 1);
    expect(status(s).isEmpty, isTrue);
  });
  test(
    'HTTP-200 rate-limit warnings fail closed and Retry cannot bypass cooldown',
    () async {
      var now = DateTime.utc(2026);
      var calls = 0;
      final s = MapDataService(
        debounce: Duration.zero,
        now: () => now,
        rpc: infraRpc((_) async => []),
        infrastructureFallback: (_) async {
          calls++;
          return {
            'items': [],
            'warning': 'busy',
            'failure': 'rateLimited',
            'retry_after': 60,
          };
        },
      );
      addTearDown(s.dispose);
      s.viewport(area, 17, all);
      await settle();
      expect(s.infrastructure.failure, MapFailure.rateLimited);
      expect(status(s).retryAt, now.add(const Duration(seconds: 60)));
      for (var i = 0; i < 20; i++) {
        s.retry('infrastructure');
      }
      await settle();
      expect(calls, 1);
      now = now.add(const Duration(seconds: 61));
      s.retry('infrastructure');
      await settle();
      expect(calls, 2);
    },
  );
  test('SDK Edge Function 429 errors are rate limits, not generic unavailable errors', () async {
    final s = MapDataService(
      debounce: Duration.zero,
      rpc: infraRpc((_) async => []),
      infrastructureFallback: (_) async =>
          throw FunctionException(status: 429, details: 'busy'),
    );
    addTearDown(s.dispose);
    s.viewport(area, 17, all);
    await settle();
    expect(s.infrastructure.failure, MapFailure.rateLimited);
  });
  test('fallback timeout hides infrastructure while primary data remains available', () async {
    final pending = Completer<dynamic>();
    final s = MapDataService(
      debounce: Duration.zero,
      fallbackTimeout: const Duration(milliseconds: 2),
      rpc: infraRpc((_) async => []),
      infrastructureFallback: (_) => pending.future,
    );
    addTearDown(s.dispose);
    s.viewport(area, 17, all);
    await settle();
    expect(s.infrastructure.failure, MapFailure.timeout);
    expect(status(s).showLayerControls, isFalse);
    expect(s.schools.hasData, isTrue);
    expect(s.hazards.hasData, isTrue);
    pending.complete({
      'items': [feature()],
    });
    await settle();
    expect(status(s).showLayerControls, isFalse);
  });
  test(
    'expired or incorrectly scoped Edge cache metadata is rejected',
    () async {
      for (final payload in [
        {
          'items': [feature()],
          'fetched_at': '2020-01-01T00:00:00Z',
        },
        {
          'items': [feature()],
          'bounds': [40.0, -87.0, 40.02, -86.98],
        },
      ]) {
        final s = MapDataService(
          debounce: Duration.zero,
          rpc: infraRpc((_) async => []),
          infrastructureFallback: (_) async => payload,
        );
        s.viewport(area, 17, all);
        await settle();
        expect(status(s).showLayerControls, isFalse);
        expect(s.infrastructure.data.features, isEmpty);
        s.dispose();
      }
    },
  );
  test('force-retries and identical camera events share one pending infrastructure request', () async {
    final pending = Completer<dynamic>();
    var calls = 0;
    final s = MapDataService(
      debounce: Duration.zero,
      rpc: infraRpc((_) {
        calls++;
        return pending.future;
      }),
    );
    addTearDown(s.dispose);
    s.viewport(area, 17, all);
    await settle();
    for (var i = 0; i < 30; i++) {
      s.viewport(area, 17, all);
      s.retry('infrastructure');
    }
    await settle();
    expect(calls, 1);
    pending.complete([feature()]);
    await settle();
    expect(calls, 1);
    expect(status(s).hasCurrentData, isTrue);
  });
  test('late results stay in their own region and only the newest viewport is fetched', () async {
    final pending = Completer<dynamic>();
    var calls = 0;
    final s = MapDataService(
      debounce: Duration.zero,
      rpc: infraRpc((_) {
        calls++;
        return calls == 1 ? pending.future : Future.value([]);
      }),
    );
    addTearDown(s.dispose);
    s.viewport(area, 17, all);
    await settle();
    s.viewport(other, 17, all);
    await settle();
    pending.complete([feature()]);
    await settle();
    expect(calls, 2);
    expect(s.infrastructure.data.features, isEmpty);
    expect(s.infrastructure.bounds!.containsBounds(other), isTrue);
    expect(status(s).availability, InfrastructureAvailability.empty);
  });
  test(
    'a stale failure does not cool down an unrelated latest viewport',
    () async {
      final pending = Completer<dynamic>();
      var calls = 0;
      final s = MapDataService(
        debounce: Duration.zero,
        rpc: infraRpc((_) {
          calls++;
          return calls == 1 ? pending.future : Future.value([]);
        }),
      );
      addTearDown(s.dispose);
      s.viewport(area, 17, all);
      await settle();
      s.viewport(other, 17, all);
      await settle();
      pending.completeError(StateError('Old viewport offline'));
      await settle();
      expect(calls, 2);
      expect(s.infrastructure.error, isNull);
    },
  );
  test('zoom, extent and explicit layer preferences govern eligibility, not availability', () async {
    var calls = 0;
    final s = MapDataService(
      debounce: Duration.zero,
      rpc: infraRpc((_) async {
        calls++;
        return [];
      }),
    );
    addTearDown(s.dispose);
    s.viewport(area, 14, all);
    await settle();
    expect(calls, 0);
    expect(s.infrastructureRequestEligible, isFalse);
    s.viewport(
      const GeoBounds(south: 40, west: -88, north: 41, east: -87),
      17,
      all,
    );
    await settle();
    expect(calls, 0);
    s.viewport(area, 17, {MapLayer.schools, MapLayer.hazards});
    await settle();
    expect(calls, 0);
    s.viewport(area, 15, all);
    await settle();
    expect(calls, 1);
    expect(s.categories, isNot(contains('walkingPath')));
    s.viewport(area, 17, all);
    await settle();
    expect(calls, 2);
    expect(s.categories, contains('walkingPath'));
  });
  test(
    'toggling off an infrastructure category reuses a valid superset cache',
    () async {
      var calls = 0;
      final s = MapDataService(
        debounce: Duration.zero,
        rpc: infraRpc((_) async {
          calls++;
          return [feature()];
        }),
      );
      addTearDown(s.dispose);
      s.viewport(area, 17, all);
      await settle();
      s.viewport(area, 17, {...all}..remove(MapLayer.crossings));
      await settle();
      expect(calls, 1);
    },
  );
  test('slow optional request does not occupy a primary data slot', () async {
    final pending = Completer<dynamic>();
    final calls = <String>[];
    final s = MapDataService(
      debounce: Duration.zero,
      rpc: (name, p) {
        calls.add(name);
        return name == 'infrastructure_in_view'
            ? pending.future
            : Future.value({'items': []});
      },
    );
    addTearDown(s.dispose);
    s.viewport(area, 17, {MapLayer.sidewalks});
    await settle();
    s.viewport(other, 17, all);
    await settle();
    expect(calls, containsAll(['schools_in_view', 'hazards_in_view']));
    expect(s.schools.hasData, isTrue);
    expect(s.hazards.hasData, isTrue);
    pending.complete([]);
    await settle();
  });
  test('infrastructure pagination is bounded and marks a truncated viewport partial', () async {
    var calls = 0;
    final s = MapDataService(
      debounce: Duration.zero,
      rpc: infraRpc((_) async {
        final start = calls++ * 500;
        return List.generate(500, (i) => feature('row-${start + i}'));
      }),
    );
    addTearDown(s.dispose);
    s.viewport(area, 17, all);
    await settle();
    expect(calls, 10);
    expect(s.infrastructure.data.features, hasLength(5000));
    expect(status(s).coverage, InfrastructureCoverage.partial);
    expect(status(s).showLayerControls, isTrue);
  });
  test(
    'unchanged cached camera frames do not rebuild infrastructure controls',
    () async {
      final s = MapDataService(
        debounce: Duration.zero,
        rpc: infraRpc((_) async => [feature()]),
      );
      addTearDown(s.dispose);
      s.viewport(area, 17, all);
      await settle();
      s.viewport(area, 17, all);
      await settle();
      var changes = 0;
      s.infrastructure.addListener(() => changes++);
      for (var i = 0; i < 100; i++) {
        s.viewport(area, 17, all);
      }
      await settle();
      expect(changes, 0);
    },
  );
  test('expired cooldown does not create a periodic retry loop in a failed viewport', () async {
    var now = DateTime.utc(2026);
    var calls = 0;
    final s = MapDataService(
      debounce: Duration.zero,
      now: () => now,
      rpc: infraRpc((_) async {
        calls++;
        throw StateError('Offline');
      }),
    );
    addTearDown(s.dispose);
    s.viewport(area, 17, all);
    await settle();
    for (var i = 0; i < 3; i++) {
      now = now.add(const Duration(minutes: 1));
      s.viewport(area, 17, all);
      await settle();
    }
    expect(calls, 1);
    s.retry('infrastructure');
    await settle();
    expect(calls, 2);
  });
  test('recovery retry still works when all infrastructure preferences were turned off', () async {
    var now = DateTime.utc(2026);
    var calls = 0;
    final pending = Completer<dynamic>();
    final s = MapDataService(
      debounce: Duration.zero,
      now: () => now,
      rpc: infraRpc((_) {
        calls++;
        return calls == 1 ? pending.future : Future.value([]);
      }),
    );
    addTearDown(s.dispose);
    s.viewport(area, 17, all);
    await settle();
    s.viewport(area, 17, {MapLayer.schools, MapLayer.hazards});
    await settle();
    pending.completeError(
      const PostgrestException(message: 'busy', code: '429'),
    );
    await settle();
    expect(status(s).showLayerControls, isFalse);
    now = now.add(const Duration(seconds: 61));
    s.retry('infrastructure');
    await settle();
    expect(calls, 2);
    expect(status(s).showLayerControls, isTrue);
    expect(s.visible, {MapLayer.schools, MapLayer.hazards});
  });
  testWidgets(
    'cache expiry clears the current viewport even without a camera event',
    (tester) async {
      var now = DateTime.utc(2026);
      final deadline = now.add(const Duration(seconds: 2));
      var fail = false;
      final s = MapDataService(
        debounce: Duration.zero,
        now: () => now,
        rpc: infraRpc((_) async => []),
        infrastructureFallback: (_) async {
          if (fail) throw StateError('Offline');
          return {
            'items': [feature()],
            'expires_at': deadline.toUtc().toIso8601String(),
          };
        },
      );
      s.viewport(area, 17, all);
      await tester.pumpAndSettle();
      expect(status(s).hasCurrentData, isTrue);
      fail = true;
      now = now.add(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(status(s).hasValidCache, isFalse);
      expect(status(s).showLayerControls, isFalse);
      s.dispose();
    },
  );
  test('broken keyset responses stop instead of looping forever', () async {
    var calls = 0;
    final rows = List.generate(500, (i) => feature('row-$i'));
    final s = MapDataService(
      debounce: Duration.zero,
      rpc: infraRpc((_) async {
        calls++;
        return rows;
      }),
    );
    addTearDown(s.dispose);
    s.viewport(area, 17, all);
    await settle();
    expect(calls, 2);
    expect(s.infrastructure.failure, MapFailure.invalidResponse);
  });
}

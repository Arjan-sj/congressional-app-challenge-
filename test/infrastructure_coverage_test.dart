import 'package:congressional_app/models/infrastructure_availability.dart';
import 'package:congressional_app/services/map_data_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'infrastructure_availability_test.dart' as fixtures;

void main() {
  test(
    'empty clipped Point does not hide otherwise available infrastructure',
    () async {
      final service = MapDataService(
        debounce: Duration.zero,
        requireInfrastructureCoverage: true,
        rpc: fixtures.infraRpc(
          (_) async => {
            'items': [
              {
                'id': 'empty-crossing',
                'category': 'crossing',
                'geometry': {'type': 'Point', 'coordinates': []},
              },
              {
                'id': 'empty-line',
                'category': 'sidewalk',
                'geometry': {'type': 'LineString', 'coordinates': []},
              },
              fixtures.feature(),
            ],
            'coverage': 'complete',
            'import_coverage': 'complete',
            'fallback_required': false,
            'expires_at': DateTime.now()
                .add(const Duration(hours: 1))
                .toIso8601String(),
          },
        ),
        infrastructureFallback: (_) async =>
            throw StateError('Imported data must not use Overpass'),
      );
      addTearDown(service.dispose);
      service.viewport(fixtures.area, 17, fixtures.all);
      await fixtures.settle();
      expect(service.infrastructure.error, isNull);
      expect(service.infrastructure.data.features, hasLength(1));
      expect(
        service.infrastructure.infrastructureStatus.showLayerControls,
        isTrue,
      );
      expect(
        service.infrastructure.infrastructureStatus.coverage,
        InfrastructureCoverage.complete,
      );
    },
  );
  test(
    'measured empty-viewport baseline reduces one fallback to zero',
    () async {
      final counts = <int>[];
      for (final metadata in [false, true]) {
        var calls = 0;
        final service = MapDataService(
          debounce: Duration.zero,
          requireInfrastructureCoverage: metadata,
          rpc: fixtures.infraRpc(
            (_) async => metadata
                ? {
                    'items': [],
                    'coverage': 'complete',
                    'import_coverage': 'complete',
                    'fallback_required': false,
                    'expires_at': DateTime.now()
                        .add(const Duration(hours: 1))
                        .toIso8601String(),
                  }
                : [],
          ),
          infrastructureFallback: (_) async {
            calls++;
            return {'items': [], 'coverage': 'complete'};
          },
        );
        addTearDown(service.dispose);
        for (var i = 0; i < 20; i++) {
          service.viewport(fixtures.area, 17, fixtures.all);
          await fixtures.settle();
        }
        counts.add(calls);
      }
      expect(counts, [1, 0]);
    },
  );
  test(
    'usable imported features remain primary without an Overpass request',
    () async {
      var calls = 0;
      final service = MapDataService(
        debounce: Duration.zero,
        requireInfrastructureCoverage: true,
        rpc: fixtures.infraRpc(
          (_) async => {
            'items': [fixtures.feature()],
            'coverage': 'partial',
            'import_coverage': 'partial',
            'fallback_required': false,
            'expires_at': DateTime.now()
                .add(const Duration(hours: 1))
                .toIso8601String(),
          },
        ),
        infrastructureFallback: (_) async {
          calls++;
          return {'items': []};
        },
      );
      addTearDown(service.dispose);
      service.viewport(fixtures.area, 17, fixtures.all);
      await fixtures.settle();
      expect(calls, 0);
      expect(service.infrastructure.data.items, hasLength(1));
      expect(
        service.infrastructure.data.coverage,
        InfrastructureCoverage.partial,
      );
    },
  );
  test(
    'covered empty viewport eliminates fallback and repeated panning requests',
    () async {
      var databaseCalls = 0;
      var upstreamCalls = 0;
      final service = MapDataService(
        debounce: Duration.zero,
        requireInfrastructureCoverage: true,
        rpc: fixtures.infraRpc((_) async {
          databaseCalls++;
          return {
            'items': [],
            'import_coverage': 'complete',
            'coverage': 'complete',
            'fallback_required': false,
            'expires_at': DateTime.now()
                .add(const Duration(hours: 1))
                .toIso8601String(),
          };
        }),
        infrastructureFallback: (_) async {
          upstreamCalls++;
          return {'items': []};
        },
      );
      addTearDown(service.dispose);
      for (var i = 0; i < 20; i++) {
        service.viewport(fixtures.area, 17, fixtures.all);
        await fixtures.settle();
      }
      expect(databaseCalls, 1);
      expect(upstreamCalls, 0);
      expect(
        service.infrastructure.infrastructureStatus.availability,
        InfrastructureAvailability.cached,
      );
      expect(service.infrastructure.infrastructureStatus.isEmpty, isTrue);
      expect(
        service.infrastructure.data.coverage,
        InfrastructureCoverage.complete,
      );
    },
  );

  for (final coverage in ['missing', 'stale', 'partial']) {
    test('$coverage coverage permits exactly one cached fallback', () async {
      var upstreamCalls = 0;
      final service = MapDataService(
        debounce: Duration.zero,
        requireInfrastructureCoverage: true,
        rpc: fixtures.infraRpc(
          (_) async => {
            'items': [],
            'import_coverage': coverage,
            'coverage': 'unknown',
            'fallback_required': true,
            'expires_at': DateTime.now()
                .add(const Duration(hours: 1))
                .toIso8601String(),
          },
        ),
        infrastructureFallback: (_) async {
          upstreamCalls++;
          return {
            'items': [fixtures.feature()],
            'coverage': 'complete',
          };
        },
      );
      addTearDown(service.dispose);
      service.viewport(fixtures.area, 17, fixtures.all);
      await fixtures.settle();
      service.viewport(fixtures.area, 17, fixtures.all);
      await fixtures.settle();
      expect(upstreamCalls, 1);
      expect(service.infrastructure.data.items, hasLength(1));
    });
  }

  test('missing deployment metadata fails independently, without speculative Overpass calls', () async {
    var upstreamCalls = 0;
    final service = MapDataService(
      debounce: Duration.zero,
      requireInfrastructureCoverage: true,
      rpc: fixtures.infraRpc((_) async => []),
      infrastructureFallback: (_) async {
        upstreamCalls++;
        return {'items': []};
      },
    );
    addTearDown(service.dispose);
    service.viewport(fixtures.area, 17, fixtures.all);
    await fixtures.settle();
    expect(upstreamCalls, 0);
    expect(
      service.infrastructure.infrastructureStatus.showLayerControls,
      isFalse,
    );
    expect(service.schools.hasData, isTrue);
    expect(service.hazards.hasData, isTrue);
  });
}

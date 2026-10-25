import 'dart:convert';

import 'package:congressional_app/models/infrastructure_availability.dart';
import 'package:congressional_app/models/map_layer.dart';
import 'package:congressional_app/screens/explore_screen.dart';
import 'package:congressional_app/services/map_data_service.dart';
import 'package:congressional_app/widgets/map_layer_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';

Widget controls(
  InfrastructureStatus status, {
  VoidCallback? retry,
  double zoom = 17,
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: MapLayerControls(
        visibleLayers: MapLayer.values.toSet(),
        featureCounts: const {},
        onLayerChanged: (_, _) {},
        loading: status.availability == InfrastructureAvailability.loading,
        zoom: zoom,
        infrastructureStatus: status,
        onRetry: retry,
      ),
    ),
  ),
);
void expectOptionalChips(bool visible) {
  for (final layer in MapLayer.values) {
    expect(
      find.byKey(ValueKey('layer-${layer.name}')),
      layer == MapLayer.schools || layer == MapLayer.hazards || visible
          ? findsOneWidget
          : findsNothing,
    );
  }
}

class _TestTileProvider extends TileProvider {
  static final _pixel = MemoryImage(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    ),
  );
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      _pixel;
}

class _TestTile implements TileImage {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'failure removes all five optional chips and keeps Schools, Hazards and retry',
    (tester) async {
      var retries = 0;
      await tester.pumpWidget(
        controls(
          const InfrastructureStatus(
            availability: InfrastructureAvailability.unavailable,
            coverage: InfrastructureCoverage.unavailable,
            lastAttemptFailed: true,
          ),
          retry: () => retries++,
        ),
      );
      expectOptionalChips(false);
      expect(
        find.text('Infrastructure information is temporarily unavailable.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('retry-infrastructure')));
      expect(retries, 1);
      await tester.pumpWidget(
        controls(
          const InfrastructureStatus(
            availability: InfrastructureAvailability.loading,
            lastAttemptFailed: true,
          ),
          retry: () => retries++,
        ),
      );
      expectOptionalChips(false);
      await tester.pumpWidget(
        controls(
          const InfrastructureStatus(
            availability: InfrastructureAvailability.available,
            coverage: InfrastructureCoverage.complete,
          ),
        ),
      );
      expectOptionalChips(true);
      expect(find.textContaining('query completed'), findsOneWidget);
    },
  );
  testWidgets('valid cached data keeps controls during a failed refresh', (
    tester,
  ) async {
    await tester.pumpWidget(
      controls(
        const InfrastructureStatus(
          availability: InfrastructureAvailability.cached,
          coverage: InfrastructureCoverage.partial,
          hasValidCache: true,
          lastAttemptFailed: true,
        ),
        retry: () {},
      ),
    );
    expectOptionalChips(true);
    expect(find.textContaining('refresh failed'), findsOneWidget);
    expect(find.textContaining('coverage: partial'), findsOneWidget);
  });
  testWidgets(
    'successful empty and cached empty data keep controls and explain missing mapping',
    (tester) async {
      await tester.pumpWidget(
        controls(
          const InfrastructureStatus(
            availability: InfrastructureAvailability.empty,
          ),
        ),
      );
      expectOptionalChips(true);
      expect(find.textContaining('No mapped infrastructure'), findsOneWidget);
      expect(find.byKey(const ValueKey('retry-infrastructure')), findsNothing);
      await tester.pumpWidget(
        controls(
          const InfrastructureStatus(
            availability: InfrastructureAvailability.cached,
            hasValidCache: true,
            isEmpty: true,
          ),
        ),
      );
      expect(
        find.textContaining(
          'cached response contains no mapped infrastructure',
        ),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'cooldown retry is disabled and controls remain accessible at enlarged mobile text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: MapLayerControls(
                visibleLayers: MapLayer.values.toSet(),
                featureCounts: const {},
                onLayerChanged: (_, _) {},
                loading: false,
                zoom: 17,
                onRetry: () {},
                infrastructureStatus: InfrastructureStatus(
                  availability: InfrastructureAvailability.unavailable,
                  lastAttemptFailed: true,
                  coverage: InfrastructureCoverage.unavailable,
                  retryAt: DateTime.utc(2026, 10, 25),
                ),
              ),
            ),
          ),
        ),
      );
      expectOptionalChips(false);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('retry-infrastructure')),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('zoomed-out recovery explains why retry is disabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      controls(
        const InfrastructureStatus(
          availability: InfrastructureAvailability.unavailable,
          lastAttemptFailed: true,
        ),
        zoom: 14,
        retry: () {},
      ),
    );
    expectOptionalChips(false);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('retry-infrastructure')),
          )
          .onPressed,
      isNull,
    );
    expect(find.text('Retry infrastructure (zoom in first)'), findsOneWidget);
  });
  testWidgets(
    'Explore restores hidden controls after successful retry without changing layer selection',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var fail = true;
      var now = DateTime.utc(2026);
      var calls = 0;
      final service = MapDataService(
        debounce: Duration.zero,
        now: () => now,
        rpc: (name, p) async {
          if (name != 'infrastructure_in_view') return {'items': []};
          calls++;
          if (fail) {
            throw const MapDataException(
              MapFailure.connectionOrCors,
              'Offline',
              retryAfter: Duration(seconds: 2),
            );
          }
          return [];
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExploreScreen(
              reports: const [],
              onReportAt: (_, _) {},
              onSelectLocation: (_, _) {},
              enableMapTiles: false,
              mapDataService: service,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expectOptionalChips(false);
      expect(calls, 1);
      expect(service.visible, MapLayer.values.toSet());
      now = now.add(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      fail = false;
      final retry = find.byKey(const ValueKey('retry-infrastructure'));
      await tester.ensureVisible(retry);
      await tester.pumpAndSettle();
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expectOptionalChips(true);
      expect(calls, 2);
      expect(find.textContaining('No mapped infrastructure'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'basemap tile errors do not hide successfully loaded infrastructure controls',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final service = MapDataService(
        debounce: Duration.zero,
        rpc: (name, p) async =>
            name == 'infrastructure_in_view' ? [] : {'items': []},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExploreScreen(
              reports: const [],
              onReportAt: (_, _) {},
              onSelectLocation: (_, _) {},
              mapDataService: service,
              tileProvider: _TestTileProvider(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      tester.widget<TileLayer>(find.byType(TileLayer)).errorTileCallback!(
        _TestTile(),
        StateError('Tile offline'),
        null,
      );
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.textContaining('Base map tiles unavailable'), findsOneWidget);
      expectOptionalChips(true);
      expect(service.infrastructure.error, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}

import 'dart:convert';

import 'package:congressional_app/models/safety_route.dart';
import 'package:congressional_app/services/open_route_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('Supabase transport compares both profiles without a client ORS key and preserves avoidance', () async {
    final requestedProfiles = <String>[];
    final client = SupabaseClient(
      'https://example.supabase.co',
      'public-project-key',
      httpClient: MockClient((request) async {
        expect(request.url.host, 'example.supabase.co');
        expect(request.url.path, '/functions/v1/route-directions');
        expect(request.headers['apikey'], 'public-project-key');
        expect(request.headers['Authorization'], isNot(contains('ors-secret')));
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        requestedProfiles.add(body['profile'] as String);
        expect(body['coordinates'], [
          [-88.1, 42.0],
          [-88.11, 42.01],
        ]);
        expect(body['options']['avoid_polygons']['type'], 'Polygon');
        expect(body.containsKey('api_key'), isFalse);
        return _routeResponse();
      }),
    );
    addTearDown(client.dispose);
    final service = OpenRouteService.supabase(client);
    addTearDown(service.close);
    expect(service.apiKey, isEmpty);
    expect(service.isConfigured, isTrue);
    final routes = await service.compare(
      origin: const LatLng(42, -88.1),
      destination: const LatLng(42.01, -88.11),
      avoidLocations: const [LatLng(42.005, -88.105)],
    );
    expect(routes, hasLength(2));
    expect(
      requestedProfiles,
      unorderedEquals(['foot-walking', 'cycling-regular']),
    );
    expect(routes.every((r) => r.avoidedHazards == 1), isTrue);
  });
  test(
    'Edge Function rate limit becomes a routing error and can recover',
    () async {
      var limited = true;
      final client = SupabaseClient(
        'https://example.supabase.co',
        'public-project-key',
        httpClient: MockClient(
          (_) async => limited
              ? http.Response(
                  '{"error":"cooling down"}',
                  429,
                  headers: {'content-type': 'application/json'},
                )
              : _routeResponse(),
        ),
      );
      addTearDown(client.dispose);
      final service = OpenRouteService.supabase(client);
      addTearDown(service.close);
      Future<List<RouteCandidate>> load() => service.fetchRoutes(
        origin: const LatLng(42, -88.1),
        destination: const LatLng(42.01, -88.11),
        profile: RouteProfile.walking,
      );
      await expectLater(
        load(),
        throwsA(
          isA<RouteServiceException>().having(
            (e) => e.failure,
            'failure',
            RouteFailure.rateLimited,
          ),
        ),
      );
      limited = false;
      expect(await load(), hasLength(1));
    },
  );
  test('equivalent concurrent and repeated routes use one ORS request; hazards, profiles and expiry stay distinct', () async {
    var calls = 0;
    var now = DateTime.utc(2026);
    final service = OpenRouteService(
      apiKey: 'test',
      now: () => now,
      client: MockClient((_) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return _routeResponse();
      }),
    );
    addTearDown(service.close);
    Future<List<RouteCandidate>> load({
      RouteProfile profile = RouteProfile.walking,
      List<LatLng> avoid = const [],
    }) => service.fetchRoutes(
      origin: const LatLng(42, -88.1),
      destination: const LatLng(42.01, -88.11),
      profile: profile,
      avoidLocations: avoid,
    );
    await Future.wait(List.generate(20, (_) => load()));
    await load();
    expect(calls, 1);
    await load(profile: RouteProfile.cycling);
    await load(avoid: const [LatLng(42.005, -88.105)]);
    expect(calls, 3);
    now = now.add(const Duration(seconds: 31));
    await load();
    expect(calls, 4);
    service.clearCache();
    await load();
    expect(calls, 5);
  });
  test('failed route requests are never cached', () async {
    var calls = 0;
    final service = OpenRouteService(
      apiKey: 'test',
      client: MockClient((_) async {
        calls++;
        return calls == 1 ? http.Response('limited', 429) : _routeResponse();
      }),
    );
    addTearDown(service.close);
    Future<List<RouteCandidate>> load() => service.fetchRoutes(
      origin: const LatLng(42, -88.1),
      destination: const LatLng(42.01, -88.11),
      profile: RouteProfile.walking,
    );
    await expectLater(load(), throwsA(isA<RouteServiceException>()));
    expect(await load(), hasLength(1));
    expect(calls, 2);
  });
  test('requests GeoJSON with longitude-latitude coordinate order', () async {
    final service = OpenRouteService(
      apiKey: 'test-key',
      client: MockClient((request) async {
        expect(request.url.path, '/v2/directions/foot-walking/geojson');
        expect(request.headers['Authorization'], 'test-key');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['coordinates'], [
          [-88.1, 42.0],
          [-88.11, 42.01],
        ]);
        expect(body['alternative_routes'], isA<Map<String, dynamic>>());
        expect(body.containsKey('options'), isFalse);
        return http.Response(
          jsonEncode({
            'type': 'FeatureCollection',
            'features': [
              {
                'type': 'Feature',
                'geometry': {
                  'type': 'LineString',
                  'coordinates': [
                    [-88.1, 42.0],
                    [-88.11, 42.01],
                  ],
                },
                'properties': {
                  'summary': {'distance': 1400, 'duration': 900},
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/geo+json'},
        );
      }),
    );

    final routes = await service.fetchRoutes(
      origin: const LatLng(42, -88.1),
      destination: const LatLng(42.01, -88.11),
      profile: RouteProfile.walking,
    );

    expect(routes, hasLength(1));
    expect(routes.single.points.last, const LatLng(42.01, -88.11));
    expect(routes.single.distanceMeters, 1400);
    expect(routes.single.durationSeconds, 900);
    expect(routes.single.avoidedHazards, 0);
  });

  test('sends a closed 100 m hazard buffer as an avoid polygon', () async {
    const hazard = LatLng(42.005, -88.105);
    final service = OpenRouteService(
      apiKey: 'test-key',
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final options = body['options'] as Map<String, dynamic>;
        final geometry = options['avoid_polygons'] as Map<String, dynamic>;
        expect(geometry['type'], 'Polygon');
        final rings = geometry['coordinates'] as List<dynamic>;
        final ring = rings.single as List<dynamic>;
        expect(ring, hasLength(25));
        expect(ring.first, ring.last);

        final firstCoordinate = ring.first as List<dynamic>;
        final firstPoint = LatLng(
          (firstCoordinate[1] as num).toDouble(),
          (firstCoordinate[0] as num).toDouble(),
        );
        expect(
          const Distance().as(LengthUnit.Meter, hazard, firstPoint),
          closeTo(100, 0.5),
        );
        return _routeResponse();
      }),
    );

    final routes = await service.fetchRoutes(
      origin: const LatLng(42, -88.1),
      destination: const LatLng(42.01, -88.11),
      profile: RouteProfile.walking,
      avoidLocations: const [hazard],
    );

    expect(routes.single.avoidedHazards, 1);
  });

  test('uses a multipolygon for distinct active report locations', () async {
    final service = OpenRouteService(
      apiKey: 'test-key',
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final geometry =
            (body['options'] as Map<String, dynamic>)['avoid_polygons']
                as Map<String, dynamic>;
        expect(geometry['type'], 'MultiPolygon');
        expect(geometry['coordinates'] as List<dynamic>, hasLength(2));
        return _routeResponse();
      }),
    );

    final routes = await service.fetchRoutes(
      origin: const LatLng(42, -88.1),
      destination: const LatLng(42.02, -88.12),
      profile: RouteProfile.cycling,
      avoidLocations: const [LatLng(42.005, -88.105), LatLng(42.015, -88.115)],
    );

    expect(routes.single.avoidedHazards, 2);
  });

  test('rejects an endpoint inside an active report buffer', () async {
    final service = OpenRouteService(
      apiKey: 'test-key',
      client: MockClient((_) async => fail('HTTP should not be called')),
    );

    await expectLater(
      service.fetchRoutes(
        origin: const LatLng(42, -88.1),
        destination: const LatLng(42.01, -88.11),
        profile: RouteProfile.walking,
        avoidLocations: const [LatLng(42.0002, -88.1)],
      ),
      throwsA(
        isA<RouteServiceException>().having(
          (error) => error.failure,
          'failure',
          RouteFailure.endpointInsideHazard,
        ),
      ),
    );
  });

  test('applies the same avoidance areas to walking and cycling', () async {
    final paths = <String>[];
    final geometries = <String>[];
    final service = OpenRouteService(
      apiKey: 'test-key',
      client: MockClient((request) async {
        paths.add(request.url.path);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        geometries.add(
          jsonEncode(
            (body['options'] as Map<String, dynamic>)['avoid_polygons'],
          ),
        );
        return _routeResponse();
      }),
    );

    await service.compare(
      origin: const LatLng(42, -88.1),
      destination: const LatLng(42.01, -88.11),
      avoidLocations: const [LatLng(42.005, -88.105)],
    );

    expect(paths, contains('/v2/directions/foot-walking/geojson'));
    expect(paths, contains('/v2/directions/cycling-regular/geojson'));
    expect(geometries, hasLength(2));
    expect(geometries.first, geometries.last);
  });

  test('requires an API key before making a request', () async {
    final service = OpenRouteService(
      apiKey: '',
      client: MockClient((_) async => fail('HTTP should not be called')),
    );

    await expectLater(
      service.compare(
        origin: const LatLng(42, -88),
        destination: const LatLng(42.01, -88.01),
      ),
      throwsA(
        isA<RouteServiceException>().having(
          (error) => error.failure,
          'failure',
          RouteFailure.missingApiKey,
        ),
      ),
    );
  });
}

http.Response _routeResponse() => http.Response(
  jsonEncode({
    'type': 'FeatureCollection',
    'features': [
      {
        'type': 'Feature',
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            [-88.1, 42.0],
            [-88.11, 42.01],
          ],
        },
        'properties': {
          'summary': {'distance': 1400, 'duration': 900},
        },
      },
    ],
  }),
  200,
  headers: {'content-type': 'application/geo+json'},
);

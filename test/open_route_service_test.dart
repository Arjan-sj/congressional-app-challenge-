import 'dart:convert';

import 'package:congressional_app/models/safety_route.dart';
import 'package:congressional_app/services/open_route_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

void main() {
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

import 'dart:convert';

import 'package:congressional_app/models/geo_bounds.dart';
import 'package:congressional_app/models/osm_infrastructure.dart';
import 'package:congressional_app/services/overpass_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const bounds = GeoBounds(
    south: 42.00,
    west: -88.12,
    north: 42.04,
    east: -88.08,
  );

  test('decodes all requested OSM infrastructure and reuses cache', () async {
    var requests = 0;
    final completedChunks = <int>[];
    final client = MockClient((request) async {
      requests++;
      expect(request.method, 'POST');
      final body = Uri.splitQueryString(request.body)['data']!;
      expect(body, contains('nwr["amenity"="school"]'));
      expect(body, contains('way["sidewalk"]'));
      expect(body, contains('nwr["highway"="crossing"]'));
      expect(body, contains('way["cycleway"]'));
      return http.Response(
        jsonEncode({
          'elements': [
            {
              'type': 'node',
              'id': 1,
              'lat': 42.02,
              'lon': -88.10,
              'tags': {'amenity': 'school', 'name': 'Public School'},
            },
            {
              'type': 'way',
              'id': 2,
              'tags': {'highway': 'footway', 'footway': 'sidewalk'},
              'geometry': [
                {'lat': 42.01, 'lon': -88.11},
                {'lat': 42.02, 'lon': -88.10},
              ],
            },
            {
              'type': 'node',
              'id': 3,
              'lat': 42.021,
              'lon': -88.101,
              'tags': {'highway': 'crossing'},
            },
            {
              'type': 'way',
              'id': 4,
              'tags': {'highway': 'cycleway'},
              'geometry': [
                {'lat': 42.01, 'lon': -88.09},
                {'lat': 42.03, 'lon': -88.09},
              ],
            },
            {
              'type': 'way',
              'id': 5,
              'tags': {'highway': 'residential', 'cycleway': 'lane'},
              'geometry': [
                {'lat': 42.01, 'lon': -88.08},
                {'lat': 42.03, 'lon': -88.08},
              ],
            },
            {
              'type': 'way',
              'id': 6,
              'tags': {'highway': 'residential', 'sidewalk': 'no'},
              'geometry': [
                {'lat': 42.01, 'lon': -88.07},
                {'lat': 42.03, 'lon': -88.07},
              ],
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final service = OverpassService(client: client);

    final first = await service.fetch(
      bounds,
      onProgress: (_, completed, total) {
        expect(total, 4);
        completedChunks.add(completed);
      },
    );
    final second = await service.fetch(bounds);

    expect(requests, 4);
    expect(completedChunks, [1, 2, 3, 4]);
    expect(identical(first, second), isTrue);
    expect(first.ofType(InfrastructureType.school), hasLength(1));
    expect(first.ofType(InfrastructureType.sidewalk), hasLength(1));
    expect(first.ofType(InfrastructureType.crossing), hasLength(1));
    expect(first.ofType(InfrastructureType.bikePath), hasLength(1));
    expect(first.ofType(InfrastructureType.bikeLane), hasLength(1));
  });

  test('turns Overpass rate limiting into an actionable error', () async {
    final service = OverpassService(
      client: MockClient((_) async => http.Response('busy', 429)),
      chunkRows: 1,
      chunkColumns: 1,
    );

    await expectLater(
      service.fetch(bounds),
      throwsA(
        isA<OverpassException>().having(
          (error) => error.failure,
          'failure',
          OverpassFailure.rateLimited,
        ),
      ),
    );
  });

  test('retries a timed out chunk', () async {
    var requests = 0;
    final service = OverpassService(
      client: MockClient((_) async {
        requests++;
        if (requests == 1) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        return http.Response(jsonEncode({'elements': []}), 200);
      }),
      requestTimeout: const Duration(milliseconds: 5),
      chunkRows: 1,
      chunkColumns: 1,
      maxRetries: 1,
    );

    final snapshot = await service.fetch(bounds);

    expect(requests, 2);
    expect(snapshot.features, isEmpty);
  });

  test('falls back when the primary endpoint has a network error', () async {
    final requestedHosts = <String>[];
    final service = OverpassService(
      client: MockClient((request) async {
        requestedHosts.add(request.url.host);
        if (request.url.host == 'primary.example') {
          throw http.ClientException('NetworkError', request.url);
        }
        return http.Response(jsonEncode({'elements': []}), 200);
      }),
      endpoint: Uri.parse('https://primary.example/api/interpreter'),
      fallbackEndpoints: [
        Uri.parse('https://fallback.example/api/interpreter'),
      ],
      chunkRows: 1,
      chunkColumns: 1,
      maxRetries: 1,
    );

    final snapshot = await service.fetch(bounds);

    expect(requestedHosts, ['primary.example', 'fallback.example']);
    expect(snapshot.features, isEmpty);
  });

  test('turns a browser network failure into an actionable error', () async {
    final service = OverpassService(
      client: MockClient(
        (request) async => throw http.ClientException(
          'NetworkError when attempting to fetch resource',
          request.url,
        ),
      ),
      endpoint: Uri.parse('https://unavailable.example/api/interpreter'),
      chunkRows: 1,
      chunkColumns: 1,
      maxRetries: 0,
    );

    await expectLater(
      service.fetch(bounds),
      throwsA(
        isA<OverpassException>()
            .having(
              (error) => error.failure,
              'failure',
              OverpassFailure.unavailable,
            )
            .having(
              (error) => error.message,
              'message',
              contains('Could not connect'),
            ),
      ),
    );
  });

  test('refuses world-scale infrastructure requests', () {
    expect(
      () => OverpassService(
        client: MockClient((_) async => http.Response('{}', 200)),
      ).fetch(const GeoBounds(south: 30, west: -100, north: 50, east: -70)),
      throwsA(isA<OverpassException>()),
    );
  });
}

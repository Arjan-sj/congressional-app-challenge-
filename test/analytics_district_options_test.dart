import 'dart:convert';

import 'package:congressional_app/models/analytics.dart';
import 'package:congressional_app/models/school_district.dart';
import 'package:congressional_app/services/analytics_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AnalyticsBucket;

void main() {
  final districtRows = [
    {
      'id': 'nces-lea:0100005',
      'name': 'Union School District',
      'state': 'AL',
      'source_year': '2024-2025',
      'school_count': 6,
      'legacy': false,
    },
    {
      'id': 'nces-lea:0100006',
      'name': 'Union School District',
      'state': 'AL',
      'source_year': '2024-2025',
      'school_count': 4,
      'legacy': false,
    },
    {
      'id': 'nces-lea:1730450',
      'name': 'Union School District',
      'state': 'IL',
      'source_year': '2024-2025',
      'school_count': 2,
      'legacy': false,
    },
    {
      'id': 'Existing district text',
      'name': 'Existing district text',
      'state': null,
      'legacy': true,
    },
  ];

  test('same-name district options retain distinct identities and labels', () {
    final options = districtRows.map(AnalyticsDistrictOption.fromJson).toList();
    expect(options.map((option) => option.id).toSet(), hasLength(4));
    expect(options.map((option) => option.displayLabel).toSet(), hasLength(4));
    expect(options[0].displayLabel, contains('AL'));
    expect(options[0].displayLabel, contains('0100005'));
    expect(options[1].displayLabel, contains('0100006'));
    expect(options[2].displayLabel, contains('IL'));
    expect(options[0].schoolCount, 6);
    expect(options[0].sourceYear, '2024-2025');
    expect(options.last.legacy, isTrue);
    expect(options.last.state, isNull);
    expect(options.last.schoolCount, 0);
    expect(options.last.displayLabel, 'Existing district text (unlinked)');
  });

  test('district filters keep stable IDs and legacy text in the existing RPC parameter', () {
    final filter = AnalyticsFilter(
      from: DateTime.utc(2026, 10, 1),
      to: DateTime.utc(2026, 10, 24),
      districts: {
        'nces-lea:0100005',
        'nces-lea:0100006',
        'Existing district text',
      },
    );
    expect(filter.toRpcParams()['p_districts'], [
      'nces-lea:0100005',
      'nces-lea:0100006',
      'Existing district text',
    ]);
    expect(filter.copyWith().districts, filter.districts);
    expect(
      filter.copyWith(districts: {}).toRpcParams().containsKey('p_districts'),
      isFalse,
    );
  });

  test(
    'repository loads normalized options while preserving legacy district API',
    () async {
      final requestedPaths = <String>[];
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-publishable-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requestedPaths.add(request.url.path);
          final Object rows;
          if (request.url.path.endsWith('/analytics_district_options')) {
            rows = districtRows;
          } else if (request.url.path.endsWith('/analytics_school_districts')) {
            rows = ['Existing district text'];
          } else {
            throw StateError('Unexpected district RPC');
          }
          return http.Response(
            jsonEncode(rows),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.dispose);
      final repository = AnalyticsRepository(client);
      final options = await repository.fetchDistrictOptions();
      expect(
        options.map((option) => option.id).toList(),
        districtRows.map((row) => row['id']).toList(),
      );
      expect(await repository.fetchDistricts(), ['Existing district text']);
      expect(requestedPaths, [
        '/rest/v1/rpc/analytics_district_options',
        '/rest/v1/rpc/analytics_school_districts',
      ]);
    },
  );
}

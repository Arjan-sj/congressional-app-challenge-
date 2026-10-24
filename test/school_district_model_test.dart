import 'dart:convert';

import 'package:congressional_app/models/analytics.dart';
import 'package:congressional_app/services/map_data_service.dart';
import 'package:congressional_app/services/urban_schools_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> mapSchool([Map<String, dynamic> extra = const {}]) => {
  'id': '010000500870',
  'name': 'Example public school',
  'district': 'Official district name',
  'district_id': 'nces-lea:0100005',
  'classification': 'public',
  'state': 'AL',
  'latitude': 34.267,
  'longitude': -86.205,
  'source_year': '2024-2025',
  ...extra,
};

void main() {
  test(
    'map school keeps normalized relationship and existing display fields',
    () {
      final school = MapDataService.schoolFromRow(mapSchool());
      expect(school.id, '010000500870');
      expect(school.districtId, 'nces-lea:0100005');
      expect(school.district, 'Official district name');
      expect(school.state, 'AL');
      expect(school.latitude, 34.267);
      expect(school.longitude, -86.205);
      expect(school.sourceYear, '2024-2025');
    },
  );

  test(
    'old RPC rows retain nullable relationship and legacy text behavior',
    () {
      final legacy = mapSchool()..remove('district_id');
      expect(MapDataService.schoolFromRow(legacy).districtId, isNull);
      expect(
        MapDataService.schoolFromRow(legacy).district,
        'Official district name',
      );
      expect(
        MapDataService.schoolFromRow(mapSchool({'district': null})).district,
        'District unavailable',
      );
    },
  );

  test('private schools and malformed IDs never gain a CCD relationship', () {
    final private = MapDataService.schoolFromRow(
      mapSchool({'classification': 'private'}),
    );
    expect(private.classification, 'private');
    expect(private.districtId, isNull);
    for (final value in ['0100005', 'District 5', 'nces-lea:100005', 100005]) {
      expect(
        MapDataService.schoolFromRow(mapSchool({'district_id': value}))
            .districtId,
        isNull,
      );
    }
  });

  test(
    'Analytics school options and exports preserve nullable district IDs',
    () {
      final row = mapSchool({'categories': [], 'severities': []});
      expect(
        AnalyticsSchoolOption.fromJson(row).districtId,
        'nces-lea:0100005',
      );
      final rollup = SchoolAnalytics.fromJson(row);
      expect(rollup.districtId, 'nces-lea:0100005');
      expect(rollup.toJson()['district_id'], 'nces-lea:0100005');
      final legacy = {...row}..remove('district_id');
      expect(AnalyticsSchoolOption.fromJson(legacy).districtId, isNull);
      expect(
        SchoolAnalytics.fromJson(legacy).toJson().containsKey('district_id'),
        isFalse,
      );
      expect(
        AnalyticsSchoolOption.fromJson(legacy).district,
        'Official district name',
      );
    },
  );

  test(
    'Urban fallback trusts explicit LEA relationships, not ID prefixes',
    () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'results': [
              for (final entry in [
                {'ncessch': '010000500870', 'lea_id': '0100005'},
                {'ncessch': '173045003167', 'leaid': '1730450'},
                {'ncessch': '010000500871', 'lea_id': '0100006'},
                {'ncessch': '010000500872'},
                {'ncessch': '010000500873', 'lea_id': '100005'},
              ])
                {
                  ...entry,
                  'school_name': 'Example school',
                  'lea_name': 'Shared district name',
                  'school_status': 1,
                  'school_level': 3,
                  'latitude': 34.267,
                  'longitude': -86.205,
                },
            ],
          }),
          200,
        ),
      );
      final repository = UrbanSchoolsRepository(client: client);
      addTearDown(repository.close);
      final schools = await repository.fetchState(1);
      expect(schools.map((school) => school.districtId), [
        'nces-lea:0100005',
        'nces-lea:1730450',
        'nces-lea:0100006',
        null,
        null,
      ]);
      expect(
        schools.every((school) => school.district == 'Shared district name'),
        isTrue,
      );
    },
  );
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:congressional_app/models/school.dart';
import 'package:congressional_app/services/urban_schools_repository.dart';

void main() {
  test('loads operational elementary, middle, and high schools', () async {
    final client = MockClient((request) async {
      expect(request.url.queryParameters['fips'], '17');
      return http.Response(
        jsonEncode({
          'results': [
            {
              'ncessch': '173045003167',
              'school_name': 'Schaumburg High School',
              'lea_name': 'Township HSD 211',
              'school_status': 1,
              'school_level': 3,
              'elem_cedp': 0,
              'middle_cedp': 0,
              'high_cedp': 1,
              'street_location': '1100 W Schaumburg Rd',
              'city_location': 'Schaumburg',
              'state_location': 'IL',
              'zip_location': '60194',
              'latitude': 42.027416,
              'longitude': -88.106632,
            },
            {
              'ncessch': 'closed',
              'school_name': 'Closed school',
              'school_status': 2,
              'school_level': 1,
              'latitude': 40,
              'longitude': -88,
            },
          ],
        }),
        200,
      );
    });
    final repository = UrbanSchoolsRepository(client: client);

    final schools = await repository.fetchState(17);

    expect(schools, hasLength(1));
    expect(schools.single.name, 'Schaumburg High School');
    expect(schools.single.levels, {SchoolLevel.high});
    expect(schools.single.address, contains('Schaumburg IL 60194'));
    repository.close();
  });
}

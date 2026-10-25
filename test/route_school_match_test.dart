import 'package:congressional_app/models/school.dart';
import 'package:congressional_app/services/route_school_match.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const schaumburg = School(
    id: '1', name: 'Schaumburg High School', district: 'D211',
    address: '', city: 'Schaumburg', state: 'IL', zipCode: '',
    latitude: 42.03, longitude: -88.11, levels: {},
  );
  const other = School(
    id: '2', name: 'Schaumburg Christian School', district: '',
    address: '', city: 'Schaumburg', state: 'IL', zipCode: '',
    latitude: 42.02, longitude: -88.12, levels: {},
  );
  test('exact school names ignore letter case and excess spacing', () {
    expect(
      RouteSchoolMatch.uniqueBestMatch(
        '  sCHauMBUrg    HIGH SCHOOL  ',
        [other, schaumburg],
      )?.id,
      '1',
    );
  });
  test('unique partial match still works', () {
    expect(
      RouteSchoolMatch.uniqueBestMatch('SCHAuMBurg', [schaumburg])?.id,
      '1',
    );
  });
  test('ambiguous searches do not silently choose a random school', () {
    expect(
      RouteSchoolMatch.uniqueBestMatch('schaumburg', [other, schaumburg]),
      isNull,
    );
    expect(RouteSchoolMatch.ambiguousMessage([other,schaumburg]),
        contains('Schaumburg High School'));
  });
  test('same school names at different campuses remain ambiguous', () {
    const duplicate = School(
      id: '3', name: 'SCHAUMBURG HIGH SCHOOL', district: '',
      address: '', city: 'Another city', state: 'IL', zipCode: '',
      latitude: 42.04, longitude: -88.10, levels: {},
    );
    expect(
      RouteSchoolMatch.uniqueBestMatch('schaumburg high school',
          [schaumburg, duplicate]),
      isNull,
    );
  });
}

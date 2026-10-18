import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/school.dart';

class UrbanSchoolsRepository {
  UrbanSchoolsRepository({http.Client? client})
    : _client = client ?? http.Client();

  static const dataYear = 2024;
  static const sourceName =
      'Urban Institute Education Data Portal, CCD $dataYear';
  static const _endpoint =
      'https://educationdata.urban.org/api/v1/schools/ccd/directory/$dataYear/';

  final http.Client _client;
  final Map<int, List<School>> _cache = {};

  Future<List<School>> fetchState(int fips) async {
    if (_cache[fips] case final cached?) return cached;

    final uri = Uri.parse(_endpoint)
        .replace(queryParameters: {'fips': fips.toString()});
    final response = await _client.get(uri);
    if (response.statusCode != 200) {
      throw StateError(
        'Urban Education Data API returned ${response.statusCode}.',
      );
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final rows = decoded['results'] as List<dynamic>?;
    if (rows == null) {
      throw const FormatException('School results were missing.');
    }

    final schools = rows
        .whereType<Map<String, dynamic>>()
        .map(_fromRow)
        .whereType<School>()
        .toList(growable: false);
    _cache[fips] = schools;
    return schools;
  }

  School? _fromRow(Map<String, dynamic> row) {
    // CCD status 1 means the school is currently operational.
    if (row['school_status'] != 1) return null;
    final latitude = (row['latitude'] as num?)?.toDouble();
    final longitude = (row['longitude'] as num?)?.toDouble();
    if (latitude == null || longitude == null) return null;

    final levels = <SchoolLevel>{};
    if (row['school_level'] == 1 || row['elem_cedp'] == 1) {
      levels.add(SchoolLevel.elementary);
    }
    if (row['school_level'] == 2 || row['middle_cedp'] == 1) {
      levels.add(SchoolLevel.middle);
    }
    if (row['school_level'] == 3 || row['high_cedp'] == 1) {
      levels.add(SchoolLevel.high);
    }
    if (levels.isEmpty) return null;

    final street = row['street_location']?.toString() ?? '';
    final city = row['city_location']?.toString() ?? '';
    final state = row['state_location']?.toString() ?? '';
    final zip = row['zip_location']?.toString() ?? '';
    final cityLine = [
      city,
      state,
      zip,
    ].where((part) => part.isNotEmpty).join(' ');

    return School(
      id: row['ncessch']?.toString() ?? row['school_id'].toString(),
      name: row['school_name']?.toString() ?? 'Public school',
      district: row['lea_name']?.toString() ?? 'District unavailable',
      address: [street, cityLine].where((part) => part.isNotEmpty).join(', '),
      city: city,
      state: state,
      zipCode: zip,
      latitude: latitude,
      longitude: longitude,
      levels: levels,
    );
  }

  void close() => _client.close();
}

class UsState {
  const UsState(this.fips, this.code, this.name);
  final int fips;
  final String code;
  final String name;
}

const usStates = <UsState>[
  UsState(1, 'AL', 'Alabama'),
  UsState(2, 'AK', 'Alaska'),
  UsState(4, 'AZ', 'Arizona'),
  UsState(5, 'AR', 'Arkansas'),
  UsState(6, 'CA', 'California'),
  UsState(8, 'CO', 'Colorado'),
  UsState(9, 'CT', 'Connecticut'),
  UsState(10, 'DE', 'Delaware'),
  UsState(11, 'DC', 'District of Columbia'),
  UsState(12, 'FL', 'Florida'),
  UsState(13, 'GA', 'Georgia'),
  UsState(15, 'HI', 'Hawaii'),
  UsState(16, 'ID', 'Idaho'),
  UsState(17, 'IL', 'Illinois'),
  UsState(18, 'IN', 'Indiana'),
  UsState(19, 'IA', 'Iowa'),
  UsState(20, 'KS', 'Kansas'),
  UsState(21, 'KY', 'Kentucky'),
  UsState(22, 'LA', 'Louisiana'),
  UsState(23, 'ME', 'Maine'),
  UsState(24, 'MD', 'Maryland'),
  UsState(25, 'MA', 'Massachusetts'),
  UsState(26, 'MI', 'Michigan'),
  UsState(27, 'MN', 'Minnesota'),
  UsState(28, 'MS', 'Mississippi'),
  UsState(29, 'MO', 'Missouri'),
  UsState(30, 'MT', 'Montana'),
  UsState(31, 'NE', 'Nebraska'),
  UsState(32, 'NV', 'Nevada'),
  UsState(33, 'NH', 'New Hampshire'),
  UsState(34, 'NJ', 'New Jersey'),
  UsState(35, 'NM', 'New Mexico'),
  UsState(36, 'NY', 'New York'),
  UsState(37, 'NC', 'North Carolina'),
  UsState(38, 'ND', 'North Dakota'),
  UsState(39, 'OH', 'Ohio'),
  UsState(40, 'OK', 'Oklahoma'),
  UsState(41, 'OR', 'Oregon'),
  UsState(42, 'PA', 'Pennsylvania'),
  UsState(44, 'RI', 'Rhode Island'),
  UsState(45, 'SC', 'South Carolina'),
  UsState(46, 'SD', 'South Dakota'),
  UsState(47, 'TN', 'Tennessee'),
  UsState(48, 'TX', 'Texas'),
  UsState(49, 'UT', 'Utah'),
  UsState(50, 'VT', 'Vermont'),
  UsState(51, 'VA', 'Virginia'),
  UsState(53, 'WA', 'Washington'),
  UsState(54, 'WV', 'West Virginia'),
  UsState(55, 'WI', 'Wisconsin'),
  UsState(56, 'WY', 'Wyoming'),
];

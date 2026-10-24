import 'package:latlong2/latlong.dart';

enum SchoolLevel {
  elementary('Elementary'),
  middle('Middle'),
  high('High');

  const SchoolLevel(this.label);
  final String label;
}

class School {
  const School({
    required this.id,
    required this.name,
    required this.district,
    required this.address,
    required this.city,
    required this.state,
    required this.zipCode,
    required this.latitude,
    required this.longitude,
    required this.levels,
    this.classification = 'public',
    this.sourceYear,
    this.districtId,
  });

  final String classification;
  final String? sourceYear;
  final String id;
  final String name;
  final String district;
  final String? districtId;
  final String address;
  final String city;
  final String state;
  final String zipCode;
  final double latitude;
  final double longitude;
  final Set<SchoolLevel> levels;

  LatLng get location => LatLng(latitude, longitude);

  String get levelLabel => levels.map((level) => level.label).join(' / ');
}

/// Reads a normalized NCES relationship without inferring one from a name.
/// Private schools do not participate in the public CCD district directory.
String? schoolDistrictIdFromRow(Map<String, dynamic> row) {
  if (row['classification'] == 'private') return null;
  final value = row['district_id'];
  if (value is! String || !RegExp(r'^nces-lea:[0-9]{7}$').hasMatch(value)) {
    return null;
  }
  return value;
}

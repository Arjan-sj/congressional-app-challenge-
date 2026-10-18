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
    required this.latitude,
    required this.longitude,
    required this.levels,
  });

  final String id;
  final String name;
  final String district;
  final String address;
  final double latitude;
  final double longitude;
  final Set<SchoolLevel> levels;

  LatLng get location => LatLng(latitude, longitude);

  String get levelLabel => levels.map((level) => level.label).join(' / ');
}

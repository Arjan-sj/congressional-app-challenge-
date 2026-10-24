/// A canonical school returned by the server's geographic lookup.
class NearbySchool {
  const NearbySchool({
    required this.id,
    required this.name,
    required this.distanceMeters,
    required this.latitude,
    required this.longitude,
  });

  factory NearbySchool.fromJson(Map<String, dynamic> row) => NearbySchool(
    id: row['school_id'] as String,
    name: row['name'] as String,
    distanceMeters: (row['distance_meters'] as num).toDouble(),
    latitude: (row['latitude'] as num).toDouble(),
    longitude: (row['longitude'] as num).toDouble(),
  );

  final String id;
  final String name;
  final double distanceMeters;
  final double latitude;
  final double longitude;
}

typedef NearbySchoolLookup = Future<List<NearbySchool>> Function(
  double latitude,
  double longitude,
);

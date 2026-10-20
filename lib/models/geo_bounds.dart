import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class GeoBounds {
  const GeoBounds({
    required this.south,
    required this.west,
    required this.north,
    required this.east,
  }) : assert(south <= north);

  factory GeoBounds.fromMapBounds(LatLngBounds bounds) => GeoBounds(
    south: bounds.south,
    west: bounds.longitudeWidth >= 360 ? -180 : _longitude(bounds.west),
    north: bounds.north,
    east: bounds.longitudeWidth >= 360 ? 180 : _longitude(bounds.east),
  );

  final double south;
  final double west;
  final double north;
  final double east;

  double get latitudeSpan => north - south;
  static double _longitude(double value) => (value + 180) % 360 - 180;
  double get longitudeSpan => east >= west ? east - west : east + 360 - west;
  bool get crossesAntimeridian => west > east;
  Map<String, dynamic> get rpcParams => {
    'min_lat': south,
    'min_lon': west,
    'max_lat': north,
    'max_lon': east,
  };

  LatLngBounds get mapBounds =>
      LatLngBounds(LatLng(south, west), LatLng(north, east));

  bool contains(LatLng point) =>
      point.latitude >= south &&
      point.latitude <= north &&
      (crossesAntimeridian
          ? point.longitude >= west || point.longitude <= east
          : point.longitude >= west && point.longitude <= east);

  bool containsBounds(GeoBounds other) =>
      other.south >= south &&
      other.north <= north &&
      longitudeSpan >= other.longitudeSpan &&
      (longitudeSpan == 360 ||
          ((other.west - west + 360) % 360) + other.longitudeSpan <=
              longitudeSpan + 1e-9);

  GeoBounds expanded(double fraction) {
    final latitudePadding = latitudeSpan * fraction;
    final longitudePadding = longitudeSpan * fraction;
    return GeoBounds(
      south: (south - latitudePadding).clamp(-90, 90),
      west: longitudeSpan + 2 * longitudePadding >= 360
          ? -180
          : _longitude(west - longitudePadding),
      north: (north + latitudePadding).clamp(-90, 90),
      east: longitudeSpan + 2 * longitudePadding >= 360
          ? 180
          : _longitude(east + longitudePadding),
    );
  }

  String get cacheKey => [
    (south * 100).floor(),
    (west * 100).floor(),
    (north * 100).ceil(),
    (east * 100).ceil(),
  ].join(':');

  @override
  String toString() => '$south,$west,$north,$east';
}

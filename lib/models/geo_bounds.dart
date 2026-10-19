import 'dart:math' as math;

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class GeoBounds {
  const GeoBounds({
    required this.south,
    required this.west,
    required this.north,
    required this.east,
  }) : assert(south <= north),
       assert(west <= east);

  factory GeoBounds.fromMapBounds(LatLngBounds bounds) => GeoBounds(
    south: bounds.south,
    west: bounds.west,
    north: bounds.north,
    east: bounds.east,
  );

  final double south;
  final double west;
  final double north;
  final double east;

  double get latitudeSpan => north - south;
  double get longitudeSpan => east - west;

  LatLngBounds get mapBounds =>
      LatLngBounds(LatLng(south, west), LatLng(north, east));

  bool contains(LatLng point) =>
      point.latitude >= south &&
      point.latitude <= north &&
      point.longitude >= west &&
      point.longitude <= east;

  bool containsBounds(GeoBounds other) =>
      other.south >= south &&
      other.north <= north &&
      other.west >= west &&
      other.east <= east;

  GeoBounds expanded(double fraction) {
    final latitudePadding = latitudeSpan * fraction;
    final longitudePadding = longitudeSpan * fraction;
    return GeoBounds(
      south: math.max(-85, south - latitudePadding),
      west: math.max(-180, west - longitudePadding),
      north: math.min(85, north + latitudePadding),
      east: math.min(180, east + longitudePadding),
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

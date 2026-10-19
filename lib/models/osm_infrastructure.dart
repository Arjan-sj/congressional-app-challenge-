import 'package:latlong2/latlong.dart';

import 'geo_bounds.dart';
import 'map_layer.dart';

enum InfrastructureType {
  school(MapLayer.schools),
  sidewalk(MapLayer.sidewalks),
  crossing(MapLayer.crossings),
  bikePath(MapLayer.bikePaths),
  bikeLane(MapLayer.bikeLanes);

  const InfrastructureType(this.layer);
  final MapLayer layer;
}

class OsmMapFeature {
  const OsmMapFeature({
    required this.id,
    required this.type,
    required this.points,
    this.tags = const {},
  });

  final String id;
  final InfrastructureType type;
  final List<LatLng> points;
  final Map<String, String> tags;

  String get name => tags['name']?.trim().isNotEmpty == true
      ? tags['name']!.trim()
      : type.layer.label.substring(0, type.layer.label.length - 1);

  LatLng get center {
    if (points.length == 1) return points.first;
    var latitude = 0.0;
    var longitude = 0.0;
    for (final point in points) {
      latitude += point.latitude;
      longitude += point.longitude;
    }
    return LatLng(latitude / points.length, longitude / points.length);
  }
}

class InfrastructureSnapshot {
  const InfrastructureSnapshot({
    required this.bounds,
    required this.features,
    required this.fetchedAt,
  });

  final GeoBounds bounds;
  final List<OsmMapFeature> features;
  final DateTime fetchedAt;

  Iterable<OsmMapFeature> ofType(InfrastructureType type) =>
      features.where((feature) => feature.type == type);

  Iterable<OsmMapFeature> forLayer(MapLayer layer) =>
      features.where((feature) => feature.type.layer == layer);

  int count(MapLayer layer) => forLayer(layer).length;
}

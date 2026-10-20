import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Pixel-cell index avoids checking every school against every hazard marker.
class MapMarkerIndex {
  MapMarkerIndex(Iterable<LatLng> schools, this.zoom) {
    for (final location in schools) {
      final point = _project(location);
      _cells
          .putIfAbsent((
            (point.$1 / 64).floor(),
            (point.$2 / 64).floor(),
          ), () => [])
          .add(point);
    }
  }
  final double zoom;
  final Map<(int, int), List<(double, double)>> _cells = {};
  double get _world => 256 * math.pow(2, zoom).toDouble();
  (double, double) _project(LatLng p) {
    final sin = math.sin(p.latitude.clamp(-85, 85) * math.pi / 180);
    return (
      ((p.longitude + 180) / 360 * _world) % _world,
      (.5 - math.log((1 + sin) / (1 - sin)) / (4 * math.pi)) * _world,
    );
  }

  bool nearSchool(LatLng location) {
    final point = _project(location);
    final x = (point.$1 / 64).floor(), y = (point.$2 / 64).floor();
    final columns = (_world / 64).ceil();
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        for (final school
            in _cells[((x + dx) % columns, y + dy)] ?? <(double, double)>[]) {
          final delta = (school.$1 - point.$1).abs();
          final sx = math.min(delta, _world - delta), sy = school.$2 - point.$2;
          if (sx * sx + sy * sy < 56 * 56) return true;
        }
      }
    }
    return false;
  }
}

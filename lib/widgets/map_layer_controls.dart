import 'package:flutter/material.dart';

import '../models/map_layer.dart';

class MapLayerStyle {
  const MapLayerStyle._();

  static const school = Color(0xFF6355A5);
  static const sidewalk = Color(0xFF16866F);
  static const crossing = Color(0xFFD88700);
  static const bikePath = Color(0xFF2474B5);
  static const bikeLane = Color(0xFF00A2A5);
  static const hazard = Color(0xFFE05A33);

  static Color color(MapLayer layer) => switch (layer) {
    MapLayer.schools => school,
    MapLayer.sidewalks => sidewalk,
    MapLayer.walkingPaths => sidewalk,
    MapLayer.crossings => crossing,
    MapLayer.bikePaths => bikePath,
    MapLayer.bikeLanes => bikeLane,
    MapLayer.hazards => hazard,
  };

  static IconData icon(MapLayer layer) => switch (layer) {
    MapLayer.schools => Icons.school,
    MapLayer.sidewalks => Icons.directions_walk,
    MapLayer.walkingPaths => Icons.hiking,
    MapLayer.crossings => Icons.add_road,
    MapLayer.bikePaths => Icons.route_outlined,
    MapLayer.bikeLanes => Icons.pedal_bike,
    MapLayer.hazards => Icons.warning_amber_rounded,
  };
}

class MapLayerControls extends StatelessWidget {
  const MapLayerControls({
    super.key,
    required this.visibleLayers,
    required this.featureCounts,
    required this.onLayerChanged,
    required this.loading,
    required this.zoom,
    this.error,
    this.onRetry,
  });

  final Set<MapLayer> visibleLayers;
  final Map<MapLayer, int> featureCounts;
  final void Function(MapLayer layer, bool visible) onLayerChanged;
  final bool loading;
  final double zoom;
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final infrastructureReady = zoom >= 15;
    return Semantics(
      container: true,
      label: 'Map key and layer visibility controls',
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.layers_outlined,
                      size: 19,
                      color: colors.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Map key',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ],
                ),
                if (loading) ...[
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(
                      'Loading OpenStreetMap data…',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ] else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(
                      infrastructureReady
                          ? 'OpenStreetMap + Supabase'
                          : 'Zoom in for infrastructure',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final layer in MapLayer.values)
                  FilterChip(
                    key: ValueKey('layer-${layer.name}'),
                    selected: visibleLayers.contains(layer),
                    onSelected: (selected) => onLayerChanged(layer, selected),
                    avatar: Icon(
                      MapLayerStyle.icon(layer),
                      size: 18,
                      color: MapLayerStyle.color(layer),
                    ),
                    label: Text(
                      '${layer.label} (${featureCounts[layer] ?? 0})',
                    ),
                  ),
              ],
            ),
            if (error != null) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 18, color: colors.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      error!,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colors.error),
                    ),
                  ),
                  if (onRetry != null)
                    TextButton(onPressed: onRetry, child: const Text('Retry')),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

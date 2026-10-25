import 'package:flutter/material.dart';

import '../models/map_layer.dart';
import '../models/infrastructure_availability.dart';

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
    this.infrastructureStatus = const InfrastructureStatus(),
    this.canRequestInfrastructure = true,
  });

  final Set<MapLayer> visibleLayers;
  final Map<MapLayer, int> featureCounts;
  final void Function(MapLayer layer, bool visible) onLayerChanged;
  final bool loading;
  final double zoom;
  final String? error;
  final VoidCallback? onRetry;
  final InfrastructureStatus infrastructureStatus;
  final bool canRequestInfrastructure;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final infrastructureReady = zoom >= 15;
    final status = infrastructureStatus;
    final message = switch (status.availability) {
      InfrastructureAvailability.unavailable =>
        'Infrastructure information is temporarily unavailable.',
      InfrastructureAvailability.empty =>
        'No mapped infrastructure was returned for this area.',
      InfrastructureAvailability.cached =>
        status.isEmpty
            ? 'The valid cached response contains no mapped infrastructure in this area.'
            : status.lastAttemptFailed
            ? 'Using valid cached infrastructure for this area; refresh failed.'
            : 'Using valid cached infrastructure for this area.',
      InfrastructureAvailability.loading =>
        status.hasValidCache
            ? 'Refreshing infrastructure; showing valid cached data.'
            : 'Loading infrastructure…',
      InfrastructureAvailability.available =>
        'Mapped infrastructure available for this area.',
      InfrastructureAvailability.notRequested =>
        infrastructureReady
            ? 'Enable infrastructure layers or zoom closer to load them.'
            : 'Zoom in for infrastructure.',
    };
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
                if (loading ||
                    status.availability ==
                        InfrastructureAvailability.loading) ...[
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(
                      message,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ] else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(
                      message,
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
                  if (layer == MapLayer.schools ||
                      layer == MapLayer.hazards ||
                      status.showLayerControls)
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
            const SizedBox(height: 8),
            Text(
              'OSM query coverage: ${status.coverage.name}. Missing OSM data does not prove that sidewalks or paths do not exist.',
              key: const ValueKey('infrastructure-coverage'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (status.coverage == InfrastructureCoverage.complete)
              Text(
                'The requested query completed; real-world mapping may still be incomplete.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (status.lastAttemptFailed && onRetry != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('retry-infrastructure'),
                  onPressed:
                      status.retryAt != null ||
                          loading ||
                          !infrastructureReady ||
                          !canRequestInfrastructure
                      ? null
                      : onRetry,
                  icon: const Icon(Icons.refresh),
                  label: Text(
                    !infrastructureReady || !canRequestInfrastructure
                        ? 'Retry infrastructure (zoom in first)'
                        : status.retryAt != null
                        ? 'Retry infrastructure after ${status.retryAt!.toLocal().toIso8601String().substring(11, 19)}'
                        : 'Retry infrastructure',
                  ),
                ),
              ),
            if (error != null && !status.lastAttemptFailed) ...[
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

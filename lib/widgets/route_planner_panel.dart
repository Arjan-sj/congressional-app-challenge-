import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../models/safety_route.dart';
import '../models/hazard_report.dart';
import 'app_ui.dart';
import 'address_route_entry.dart';
import '../services/address_search_service.dart';

class RoutePlannerPanel extends StatelessWidget {
  const RoutePlannerPanel({
    super.key,
    required this.selectedPoint,
    required this.origin,
    required this.destination,
    required this.configured,
    required this.loading,
    required this.assessments,
    required this.onUseAsOrigin,
    required this.onUseAsDestination,
    required this.onCompare,
    required this.onClear,
    required this.onSelectRoute,
    required this.onSetStart,
    required this.onSetEnd,
    required this.onUseCurrentLocation,
    required this.nearbyReports,
    this.selectedRouteId,
    this.error,
    this.addressSearch,
    this.onStartEdited,
    this.onEndEdited,
  });

  final Future<List<AddressSuggestion>> Function(String)? addressSearch;
  final VoidCallback? onStartEdited;
  final VoidCallback? onEndEdited;
  final LatLng? selectedPoint;
  final LatLng? origin;
  final LatLng? destination;
  final bool configured;
  final bool loading;
  final List<RouteSafetyAssessment> assessments;
  final String? selectedRouteId;
  final String? error;
  final VoidCallback onUseAsOrigin;
  final VoidCallback onUseAsDestination;
  final VoidCallback onCompare;
  final VoidCallback onClear;
  final ValueChanged<RouteSafetyAssessment> onSelectRoute;
  final Future<String?> Function(String) onSetStart;
  final Future<String?> Function(String) onSetEnd;
  final Future<void> Function() onUseCurrentLocation;
  final List<HazardReport> nearbyReports;

  String _coordinate(LatLng? point) => point == null
      ? 'Not selected'
      : '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}';

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final canCompare =
        configured && origin != null && destination != null && !loading;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(Icons.alt_route, color: colors.primary),
              Text(
                'Plan your route',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!configured)
                const Chip(
                  avatar: Icon(Icons.key_off_outlined, size: 18),
                  label: Text('API key required'),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Set a start and destination using the map or search boxes below.',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _RoutePointCard(
                label: 'Start',
                coordinate: _coordinate(origin),
                icon: Icons.trip_origin,
                actionLabel: 'Use selected point',
                onPressed: selectedPoint == null ? null : onUseAsOrigin,
              ),
              _RoutePointCard(
                label: 'Destination',
                coordinate: _coordinate(destination),
                icon: Icons.flag_outlined,
                actionLabel: 'Use selected point',
                onPressed: selectedPoint == null ? null : onUseAsDestination,
              ),
            ],
          ),
          const SizedBox(height: 14),
          AddressRouteEntry(label: 'Start location', onSet: onSetStart, search: addressSearch, point: origin, onEdited: onStartEdited),
          const SizedBox(height: 10),
          AddressRouteEntry(label: 'End location', onSet: onSetEnd, search: addressSearch, point: destination, onEdited: onEndEdited),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onUseCurrentLocation,
              icon: const Icon(Icons.my_location),
              label: const Text('Use my location as start'),
            ),
          ),
          const SizedBox(height: 6),
          const Text('Choose an address suggestion to set a location anywhere in the US. School names, coordinates and map selection still work.'),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: canCompare ? onCompare : null,
                icon: loading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.compare_arrows),
                label: Text(loading ? 'Comparing…' : 'Compare routes'),
              ),
              OutlinedButton.icon(
                onPressed: origin == null && destination == null
                    ? null
                    : onClear,
                icon: const Icon(Icons.clear),
                label: const Text('Clear route'),
              ),
            ],
          ),
          if (!configured) ...[
            const SizedBox(height: 12),
            const Text(
              'Route comparison is temporarily unavailable. Please try again later.',
            ),
          ],
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(error!, style: TextStyle(color: colors.error)),
          ],
          if (assessments.isNotEmpty) ...[
            const Divider(height: 30),
            Text('Reports near selected route (within 150 m)',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text('Nearby reports are not necessarily obstacles. '
                'Only verified reports affect the route score; '
                'unverified reports must be checked independently.',
                style: TextStyle(color: colors.onSurfaceVariant)),
            if (nearbyReports.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No active, non-demo reports found within 150 m.'),
              )
            else
              for (final report in nearbyReports)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.warning_amber_rounded),
                  title: Text(report.type.label),
                  subtitle: Text('Severity ${report.severity}/5 • ${report.status.label}'),
                ),
            const Divider(height: 30),
            Text(
              'Route options',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Routes account for verified nearby reports and available mapped infrastructure. Missing map data is not treated as unsafe.',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            for (final assessment in assessments)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _RouteResultCard(
                  assessment: assessment,
                  selected: selectedRouteId == assessment.route.id,
                  onTap: () => onSelectRoute(assessment),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _RoutePointCard extends StatelessWidget {
  const _RoutePointCard({
    required this.label,
    required this.coordinate,
    required this.icon,
    required this.actionLabel,
    required this.onPressed,
  });

  final String label;
  final String coordinate;
  final IconData icon;
  final String actionLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 250, maxWidth: 360),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: colors.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: Theme.of(context).textTheme.titleSmall),
                    Text(
                      coordinate,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: onPressed, child: Text(actionLabel)),
          ),
        ],
      ),
    );
  }
}

class _RouteResultCard extends StatelessWidget {
  const _RouteResultCard({
    required this.assessment,
    required this.selected,
    required this.onTap,
  });

  final RouteSafetyAssessment assessment;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final route = assessment.route;
    final coverage = assessment.infrastructureCoverage;
    return Material(
      color: selected ? colors.primaryContainer.withValues(alpha: .5) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? colors.primary : colors.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    route.profile == RouteProfile.walking
                        ? Icons.directions_walk
                        : Icons.pedal_bike,
                    color: colors.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${route.profile.label} • ${(route.distanceMeters / 1000).toStringAsFixed(2)} km • ${(route.durationSeconds / 60).round()} min',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  CircleAvatar(
                    backgroundColor: colors.primary,
                    foregroundColor: colors.onPrimary,
                    child: Text('${assessment.score}'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Distance −${assessment.distancePenalty.toStringAsFixed(1)} • '
                'Verified hazards −${assessment.hazardPenalty.toStringAsFixed(0)} '
                '(${assessment.nearbyVerifiedHazards}) • '
                'Mapped infrastructure +${assessment.infrastructureBonus.toStringAsFixed(1)}',
              ),
              const SizedBox(height: 4),
              Text(
                route.avoidedHazards == 0
                    ? 'No active report buffers were inside this route area.'
                    : 'Avoided ${route.avoidedHazards} active report ${route.avoidedHazards == 1 ? 'area' : 'areas'} using 100 m buffers.',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 4),
              Text(
                coverage == null
                    ? 'Infrastructure coverage: unknown in OpenStreetMap; not scored as unsafe.'
                    : 'Mapped infrastructure near ${(coverage * 100).round()}% of sampled route points${assessment.infrastructureDataComplete ? '.' : '; coverage is partial outside the loaded map area.'}',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

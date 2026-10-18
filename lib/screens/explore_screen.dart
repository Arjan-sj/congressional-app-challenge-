import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../data/pilot_school.dart';
import '../models/hazard_report.dart';

/// Displays a real interactive *basemap*, with one public school location.
/// Hazard markers are only displayed for local demo entries with coordinates.
/// No real hazards, route safety, or sidewalk verification are asserted.
class ExploreScreen extends StatefulWidget {
  const ExploreScreen({
    super.key,
    required this.reports,
    required this.onReportAt,
    required this.onSelectLocation,
    this.enableMapTiles = true,
    this.isLive = false,
  });

  final List<HazardReport> reports;
  final void Function(double latitude, double longitude) onReportAt;

  /// Called immediately on a map tap, even if the user uses the bottom
  /// Report tab rather than the secondary button below the map.
  final void Function(double latitude, double longitude) onSelectLocation;

  /// Disable external requests in widget tests while keeping map behavior.
  final bool enableMapTiles;
  final bool isLive;

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  static const String _tileUrl = String.fromEnvironment(
    'MAP_TILE_URL',
    defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  );

  final MapController _controller = MapController();
  LatLng? _selectedPoint;
  HazardType? _filter;

  List<HazardReport> get _mappedReports => widget.reports
      .where((report) => report.hasLocation)
      .where((report) => _filter == null || report.type == _filter)
      .toList();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _showReportDetails(HazardReport report) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(report.type.label, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(report.description),
            const SizedBox(height: 12),
            Text('Self-reported severity: ${report.severity}/5'),
            Text('Status: ${report.status.label}'),
            Text(report.isDemo ? 'Test entry — not verified.' : 'Community report — independently verify.'),
          ],
        ),
      ),
    );
  }

  Color _markerColor(ReportStatus status) => switch (status) {
    ReportStatus.unverified => Colors.deepOrange,
    ReportStatus.verified => Colors.green,
    ReportStatus.resolved => Colors.blueGrey,
    ReportStatus.rejected => Colors.grey,
  };

  Widget _reportMarker(HazardReport report) {
    return Tooltip(
      message: '${report.type.label} • ${report.status.label}',
      child: IconButton.filled(
        tooltip: 'View ${report.type.label} example',
        onPressed: () => _showReportDetails(report),
        icon: const Icon(Icons.report_outlined),
        style: IconButton.styleFrom(
          backgroundColor: _markerColor(report.status),
          foregroundColor: Colors.white,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mappedReports = _mappedReports;
    final mapMarkers = <Marker>[
      Marker(
        point: PilotSchool.location,
        width: 56,
        height: 56,
        child: Tooltip(
          message: PilotSchool.name,
          child: IconButton.filledTonal(
            tooltip: 'Center on ${PilotSchool.name}',
            onPressed: () => _controller.move(PilotSchool.location, 15),
            icon: const Icon(Icons.school),
          ),
        ),
      ),
      for (final report in mappedReports)
        Marker(
          point: LatLng(report.latitude!, report.longitude!),
          width: 52,
          height: 52,
          child: _reportMarker(report),
        ),
      if (_selectedPoint case final selected?)
        Marker(
          point: selected,
          width: 48,
          height: 48,
          child: const Icon(Icons.location_pin, color: Colors.indigo, size: 46),
        ),
    ];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Explore school area', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        const Text('${PilotSchool.name} • pilot area'),
        const SizedBox(height: 8),
        Text(widget.isLive ? 'Pilot database: test reports remain unverified.' : 'Tap the map to select a location, then create a DEMO report. The basemap is real; reported hazards in this app are fictional.'),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 410,
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _controller,
                  options: MapOptions(
                    initialCenter: PilotSchool.location,
                    initialZoom: 15,
                    minZoom: 10,
                    maxZoom: 19,
                    onTap: (_, location) {
                      setState(() => _selectedPoint = location);
                      widget.onSelectLocation(location.latitude, location.longitude);
                    },
                  ),
                  children: [
                    if (widget.enableMapTiles)
                      TileLayer(
                        urlTemplate: _tileUrl,
                        userAgentPackageName: 'org.saferoutes.cac.demo',
                      ),
                    MarkerLayer(markers: mapMarkers),
                  ],
                ),
                Positioned(
                  right: 10,
                  top: 10,
                  child: IconButton.filledTonal(
                    tooltip: 'Back to pilot school',
                    onPressed: () => _controller.move(PilotSchool.location, 15),
                    icon: const Icon(Icons.my_location),
                  ),
                ),
                // Visible on the map, even while the user pans or zooms.
                Positioned(
                  right: 5,
                  bottom: 4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                      child: Text(
                        '© OpenStreetMap contributors',
                        style: TextStyle(fontSize: 11, color: Colors.black87),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (_selectedPoint case final selected?)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Selected map location'),
                  Text(
                    '${selected.latitude.toStringAsFixed(5)}, '
                    '${selected.longitude.toStringAsFixed(5)}',
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: () => widget.onReportAt(
                      selected.latitude,
                      selected.longitude,
                    ),
                    icon: const Icon(Icons.add_location_alt_outlined),
                    label: const Text('Continue to report form'),
                  ),
                ],
              ),
            ),
          )
        else
          const ListTile(
            leading: Icon(Icons.touch_app_outlined),
            title: Text('Tap anywhere on the map'),
            subtitle: Text('A location must be selected before adding a map report.'),
          ),
        const SizedBox(height: 8),
        Text('Hazard filters', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Wrap(
          spacing: 7,
          runSpacing: 2,
          children: [
            ChoiceChip(
              label: const Text('All'),
              selected: _filter == null,
              onSelected: (_) => setState(() => _filter = null),
            ),
            for (final type in HazardType.values)
              ChoiceChip(
                label: Text(type.label),
                selected: _filter == type,
                onSelected: (_) => setState(() => _filter = type),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          widget.isLive ? '${mappedReports.length} records visible to this account.' : '${mappedReports.length} demo markers with selected locations. Other example reports have no map coordinates.',
        ),
        const SizedBox(height: 10),
        const ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.warning_amber_outlined),
          title: Text('Not a verified safety map'),
          subtitle: Text(
            'No pedestrian infrastructure or route safety has been verified yet. '
            'OpenStreetMap basemap labels are not a sidewalk audit.',
          ),
        ),
      ],
    );
  }
}

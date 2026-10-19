import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../data/pilot_school.dart';
import '../models/geo_bounds.dart';
import '../models/hazard_report.dart';
import '../models/map_layer.dart';
import '../models/osm_infrastructure.dart';
import '../models/safety_route.dart';
import '../models/school.dart';
import '../services/device_location_service.dart';
import '../services/hazard_avoidance_service.dart';
import '../services/open_route_service.dart';
import '../services/overpass_service.dart';
import '../services/route_safety_scorer.dart';
import '../services/urban_schools_repository.dart';
import '../widgets/app_ui.dart';
import '../widgets/hazard_photo_view.dart';
import '../widgets/map_layer_controls.dart';
import '../widgets/route_planner_panel.dart';

/// Displays a real interactive basemap with live infrastructure and reports.
class ExploreScreen extends StatefulWidget {
  const ExploreScreen({
    super.key,
    required this.reports,
    required this.onReportAt,
    required this.onSelectLocation,
    this.enableMapTiles = true,
    this.isLive = false,
    this.showMapTextAlternative = false,
    this.enableKeyboardNavigation = false,
  });

  final List<HazardReport> reports;
  final void Function(double latitude, double longitude) onReportAt;
  final void Function(double latitude, double longitude) onSelectLocation;
  final bool enableMapTiles;
  final bool isLive;
  final bool showMapTextAlternative;
  final bool enableKeyboardNavigation;

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  static const _minZoom = 4.0;
  static const _maxZoom = 19.0;
  static const _infrastructureZoom = 14.0;
  static const String _tileUrl = String.fromEnvironment(
    'MAP_TILE_URL',
    defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  );

  final MapController _controller = MapController();
  final OverpassService _overpassService = OverpassService();
  final OpenRouteService _routeService = OpenRouteService();
  final HazardAvoidanceService _hazardAvoidanceService =
      const HazardAvoidanceService();
  final DeviceLocationService _locationService = const DeviceLocationService();
  final RouteSafetyScorer _routeScorer = const RouteSafetyScorer();
  UrbanSchoolsRepository? _schoolsRepository;
  final TextEditingController _schoolSearchController = TextEditingController();
  final FocusNode _mapFocusNode = FocusNode(debugLabel: 'Community map');
  LatLng? _selectedPoint;
  LatLng? _userLocation;
  LatLng? _routeOrigin;
  LatLng? _routeDestination;
  HazardType? _filter;
  List<School> _schools = const [];
  InfrastructureSnapshot? _infrastructure;
  List<RouteSafetyAssessment> _routeAssessments = const [];
  List<LatLng> _routeAvoidLocations = const [];
  final Set<MapLayer> _visibleLayers = MapLayer.values.toSet();
  LatLngBounds? _visibleBounds;
  Timer? _infrastructureDebounce;
  int _selectedStateFips = 17;
  int _infrastructureRequestVersion = 0;
  int _routeRequestVersion = 0;
  double _zoom = 15;
  bool _loadingSchools = false;
  bool _loadingInfrastructure = false;
  bool _loadingRoutes = false;
  bool _findingLocation = false;
  bool _mapHasFocus = false;
  String? _schoolError;
  String? _infrastructureError;
  String? _routeError;
  String? _selectedRouteId;

  @override
  void initState() {
    super.initState();
    if (widget.enableMapTiles) {
      _schoolsRepository = UrbanSchoolsRepository();
      _loadSchools();
    }
  }

  List<HazardReport> get _mappedReports => widget.reports
      .where((report) => report.status != ReportStatus.rejected)
      .where((report) => report.hasLocation)
      .where((report) => _filter == null || report.type == _filter)
      .toList();

  @override
  void dispose() {
    _infrastructureDebounce?.cancel();
    _controller.dispose();
    _overpassService.close();
    _routeService.close();
    _schoolsRepository?.close();
    _schoolSearchController.dispose();
    _mapFocusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ExploreScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_routeReportSignature(oldWidget.reports) ==
        _routeReportSignature(widget.reports)) {
      return;
    }
    _routeAssessments = const [];
    _routeAvoidLocations = const [];
    _selectedRouteId = null;
    _loadingRoutes = false;
    _routeRequestVersion++;
    if (_routeOrigin != null && _routeDestination != null) {
      _routeError = 'Reports changed. Compare again to refresh avoidance.';
    }
  }

  String _routeReportSignature(Iterable<HazardReport> reports) {
    final parts =
        _hazardAvoidanceService
            .activeReports(reports)
            .map(
              (report) =>
                  '${report.id}:${report.status.name}:${report.severity}:${report.latitude}:${report.longitude}',
            )
            .toList()
          ..sort();
    return parts.join('|');
  }

  void _handleCameraChanged(MapCamera camera) {
    setState(() {
      _zoom = camera.zoom;
      _visibleBounds = camera.visibleBounds;
    });
    _scheduleInfrastructureLoad(camera.visibleBounds, camera.zoom);
  }

  void _scheduleInfrastructureLoad(LatLngBounds bounds, double zoom) {
    _infrastructureDebounce?.cancel();
    if (!widget.enableMapTiles || zoom < _infrastructureZoom) {
      if (_loadingInfrastructure || _infrastructureError != null) {
        _infrastructureRequestVersion++;
        setState(() {
          _loadingInfrastructure = false;
          _infrastructureError = null;
        });
      }
      return;
    }
    final visible = GeoBounds.fromMapBounds(bounds);
    final snapshot = _infrastructure;
    if (snapshot != null && snapshot.bounds.containsBounds(visible)) return;
    _infrastructureDebounce = Timer(
      const Duration(milliseconds: 850),
      () => _loadInfrastructure(visible),
    );
  }

  Future<void> _loadInfrastructure(
    GeoBounds bounds, {
    bool forceRefresh = false,
  }) async {
    final requestVersion = ++_infrastructureRequestVersion;
    setState(() {
      _loadingInfrastructure = true;
      _infrastructureError = null;
    });
    try {
      final snapshot = await _overpassService.fetch(
        bounds,
        forceRefresh: forceRefresh,
        onProgress: (partialSnapshot, _, _) {
          if (!mounted || requestVersion != _infrastructureRequestVersion) {
            return;
          }
          setState(() => _infrastructure = partialSnapshot);
        },
      );
      if (!mounted || requestVersion != _infrastructureRequestVersion) return;
      setState(() {
        _infrastructure = snapshot;
        _loadingInfrastructure = false;
      });
    } on TimeoutException {
      if (!mounted || requestVersion != _infrastructureRequestVersion) return;
      setState(() {
        _loadingInfrastructure = false;
        _infrastructureError = 'OpenStreetMap infrastructure timed out. The basemap and hazards still work.';
      });
    } catch (error) {
      if (!mounted || requestVersion != _infrastructureRequestVersion) return;
      setState(() {
        _loadingInfrastructure = false;
        _infrastructureError = error.toString();
      });
    }
  }

  void _retryInfrastructure() {
    final bounds = _visibleBounds;
    if (bounds == null || _zoom < _infrastructureZoom) return;
    _loadInfrastructure(GeoBounds.fromMapBounds(bounds), forceRefresh: true);
  }

  Future<void> _loadSchools({bool fitState = false}) async {
    final requestedFips = _selectedStateFips;
    setState(() {
      _loadingSchools = true;
      _schoolError = null;
    });
    try {
      final schools = await _schoolsRepository!.fetchState(requestedFips);
      if (!mounted || requestedFips != _selectedStateFips) return;
      setState(() {
        _schools = schools;
        _loadingSchools = false;
      });
      if (fitState && schools.isNotEmpty) {
        _controller.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(
              schools.map((school) => school.location).toList(),
            ),
            padding: const EdgeInsets.all(40),
          ),
        );
      }
    } catch (error) {
      if (!mounted || requestedFips != _selectedStateFips) return;
      setState(() {
        _loadingSchools = false;
        _schoolError = 'Could not load schools from Urban Institute.';
      });
    }
  }

  void _selectState(int? fips) {
    if (fips == null || fips == _selectedStateFips) return;
    setState(() {
      _selectedStateFips = fips;
      _schools = const [];
    });
    if (widget.enableMapTiles) _loadSchools(fitState: true);
  }

  void _zoomBy(double amount) {
    final nextZoom = (_controller.camera.zoom + amount)
        .clamp(_minZoom, _maxZoom)
        .toDouble();
    _controller.move(_controller.camera.center, nextZoom);
  }

  void _panMap(double horizontal, double vertical) {
    final camera = _controller.camera;
    final step = 20 / math.pow(2, camera.zoom);
    final latitude = (camera.center.latitude + vertical * step)
        .clamp(-85.0, 85.0)
        .toDouble();
    final longitude = camera.center.longitude + horizontal * step;
    _controller.move(LatLng(latitude, longitude), camera.zoom);
  }

  List<OsmMapFeature> get _osmSchools =>
      _infrastructure
          ?.ofType(InfrastructureType.school)
          .toList(growable: false) ??
      const [];

  List<OsmMapFeature> get _osmCrossings =>
      _infrastructure
          ?.ofType(InfrastructureType.crossing)
          .toList(growable: false) ??
      const [];

  List<OsmMapFeature> _features(InfrastructureType type) =>
      _infrastructure?.ofType(type).toList(growable: false) ?? const [];

  List<School> get _schoolSearchResults {
    final query = _schoolSearchController.text.trim().toLowerCase();
    if (query.isEmpty) return const [];
    final state = usStates.firstWhere(
      (candidate) => candidate.fips == _selectedStateFips,
    );
    return _schools
        .where((school) {
          final searchable = [
            school.name,
            school.city,
            school.state,
            school.zipCode,
            school.district,
            state.name,
            state.code,
          ].join(' ').toLowerCase();
          return searchable.contains(query);
        })
        .take(10)
        .toList(growable: false);
  }

  void _focusSchool(School school) {
    _controller.move(school.location, 16);
  }

  Future<void> _findCurrentLocation() async {
    if (_findingLocation) return;
    setState(() => _findingLocation = true);
    try {
      final location = await _locationService.currentLocation();
      if (!mounted) return;
      setState(() => _userLocation = location);
      _controller.move(location, 16);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => _findingLocation = false);
    }
  }

  void _useSelectedAsRouteOrigin() {
    if (_selectedPoint == null) return;
    setState(() {
      _routeOrigin = _selectedPoint;
      _routeAssessments = const [];
      _routeAvoidLocations = const [];
      _loadingRoutes = false;
      _routeRequestVersion++;
      _routeError = null;
      _selectedRouteId = null;
    });
  }

  void _useSelectedAsRouteDestination() {
    if (_selectedPoint == null) return;
    setState(() {
      _routeDestination = _selectedPoint;
      _routeAssessments = const [];
      _routeAvoidLocations = const [];
      _loadingRoutes = false;
      _routeRequestVersion++;
      _routeError = null;
      _selectedRouteId = null;
    });
  }

  void _clearRoute() {
    setState(() {
      _routeOrigin = null;
      _routeDestination = null;
      _routeAssessments = const [];
      _routeAvoidLocations = const [];
      _loadingRoutes = false;
      _routeRequestVersion++;
      _routeError = null;
      _selectedRouteId = null;
    });
  }

  Future<void> _compareRoutes() async {
    final origin = _routeOrigin;
    final destination = _routeDestination;
    if (origin == null || destination == null || _loadingRoutes) return;
    final avoidLocations = _hazardAvoidanceService.locationsForRoute(
      reports: widget.reports,
      origin: origin,
      destination: destination,
    );
    final requestVersion = ++_routeRequestVersion;
    setState(() {
      _loadingRoutes = true;
      _routeError = null;
      _routeAssessments = const [];
      _routeAvoidLocations = avoidLocations;
    });
    try {
      final routes = await _routeService.compare(
        origin: origin,
        destination: destination,
        avoidLocations: avoidLocations,
      );
      if (!mounted || requestVersion != _routeRequestVersion) return;
      final assessments = _routeScorer.score(
        routes: routes,
        hazards: widget.reports,
        infrastructure: _infrastructure,
      );
      setState(() {
        _routeAssessments = assessments;
        _selectedRouteId = assessments.isEmpty
            ? null
            : assessments.first.route.id;
        _loadingRoutes = false;
        _routeError = assessments.isEmpty
            ? 'No walking or cycling alternatives were returned for these points.'
            : null;
      });
      if (assessments.isNotEmpty) _fitRoute(assessments.first);
    } on TimeoutException {
      if (!mounted || requestVersion != _routeRequestVersion) return;
      setState(() {
        _loadingRoutes = false;
        _routeError = 'Route comparison timed out. Try again shortly.';
      });
    } catch (error) {
      if (!mounted || requestVersion != _routeRequestVersion) return;
      setState(() {
        _loadingRoutes = false;
        _routeError = error.toString();
      });
    }
  }

  void _fitRoute(RouteSafetyAssessment assessment) {
    setState(() => _selectedRouteId = assessment.route.id);
    _controller.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(assessment.route.points),
        padding: const EdgeInsets.all(46),
      ),
    );
  }

  Color _markerColor(ReportStatus status) => switch (status) {
    ReportStatus.unverified => const Color(0xFFE57532),
    ReportStatus.verified => const Color(0xFF16866F),
    ReportStatus.resolved => const Color(0xFF52717C),
    ReportStatus.rejected => const Color(0xFF7D8587),
  };

  void _showReportDetails(HazardReport report) {
    final colors = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: colors.surface,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .85,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: colors.errorContainer,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        Icons.report_gmailerrorred_outlined,
                        color: colors.onErrorContainer,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            report.type.label,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          Text(
                            report.isDemo
                                ? 'Community-submitted demo'
                                : 'Community report',
                            style: TextStyle(color: colors.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    StatusPill(label: report.status.label),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  report.description,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                if (report.photoSignedUrl case final url?) ...[
                  const SizedBox(height: 18),
                  HazardPhotoView(url: url),
                ] else if (report.hasPhoto) ...[
                  const SizedBox(height: 18),
                  const Text(
                    'Photo evidence is attached but its temporary link is unavailable. Refresh and try again.',
                  ),
                ],
                const SizedBox(height: 20),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    LabeledIcon(
                      icon: Icons.signal_cellular_alt,
                      label: 'Self-reported',
                      value: 'Severity ${report.severity}/5',
                    ),
                    LabeledIcon(
                      icon: Icons.fact_check_outlined,
                      label: 'Review status',
                      value: report.status.label,
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF6E5),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.info_outline,
                        size: 20,
                        color: Color(0xFF815500),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          report.isDemo
                              ? 'Demo data — not a verified safety finding.'
                              : 'Community report — independently verify.',
                          style: const TextStyle(color: Color(0xFF674500)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _reportMarker(HazardReport report) {
    return Tooltip(
      message: '${report.type.label} • ${report.status.label}',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _markerColor(report.status),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: IconButton(
          tooltip: 'View ${report.type.label} report',
          onPressed: () => _showReportDetails(report),
          icon: const Icon(Icons.warning_amber_rounded),
          color: Colors.white,
        ),
      ),
    );
  }

  Marker _schoolMarker(OsmMapFeature school) => Marker(
    point: school.center,
    width: 44,
    height: 44,
    child: Tooltip(
      message: school.name,
      child: IconButton.filled(
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        tooltip: 'Center ${school.name}',
        style: IconButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: MapLayerStyle.school,
          side: const BorderSide(color: MapLayerStyle.school, width: 2),
        ),
        onPressed: () => _controller.move(school.center, 17),
        icon: const Icon(Icons.school, size: 20),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final compactLayout = MediaQuery.sizeOf(context).width < 600;
    final mappedReports = _mappedReports;
    final visibleSchools = _visibleLayers.contains(MapLayer.schools)
        ? _osmSchools
        : const <OsmMapFeature>[];
    final visibleCrossings = _visibleLayers.contains(MapLayer.crossings)
        ? _osmCrossings
        : const <OsmMapFeature>[];
    final visibleReports = _visibleBounds == null
        ? const <HazardReport>[]
        : mappedReports
              .where(
                (report) => _visibleBounds!.contains(
                  LatLng(report.latitude!, report.longitude!),
                ),
              )
              .toList(growable: false);
    final searchResults = _schoolSearchResults;
    final featureCounts = {
      for (final layer in MapLayer.values)
        layer: layer == MapLayer.hazards
            ? visibleReports.length
            : _infrastructure?.count(layer) ?? 0,
    };
    final markers = <Marker>[
      for (final school in visibleSchools) _schoolMarker(school),
      for (var index = 0; index < visibleCrossings.length; index++)
        Marker(
          point: visibleCrossings[index].center,
          width: 34,
          height: 34,
          child: Tooltip(
            message: 'Mapped pedestrian crossing • OpenStreetMap',
            child: DecoratedBox(
              key: ValueKey('crossing-marker-$index'),
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: MapLayerStyle.crossing, width: 3),
                boxShadow: const [
                  BoxShadow(color: Color(0x29000000), blurRadius: 6),
                ],
              ),
              child: const Icon(
                Icons.directions_walk,
                size: 19,
                color: MapLayerStyle.crossing,
              ),
            ),
          ),
        ),
      if (_visibleLayers.contains(MapLayer.hazards))
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
          width: 50,
          height: 50,
          child: Icon(Icons.location_pin, color: colors.primary, size: 48),
        ),
      if (_routeOrigin case final origin?)
        Marker(
          point: origin,
          width: 42,
          height: 42,
          child: const Tooltip(
            message: 'Route start',
            child: Icon(Icons.trip_origin, color: Color(0xFF6A45A5), size: 34),
          ),
        ),
      if (_routeDestination case final destination?)
        Marker(
          point: destination,
          width: 42,
          height: 42,
          child: const Tooltip(
            message: 'Route destination',
            child: Icon(Icons.flag, color: Color(0xFFB13C35), size: 36),
          ),
        ),
      if (_userLocation case final location?)
        Marker(
          point: location,
          width: 34,
          height: 34,
          child: const Tooltip(
            message: 'Your approximate location',
            child: Icon(Icons.my_location, color: Color(0xFF1769AA), size: 28),
          ),
        ),
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 40),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const PageIntro(
                  eyebrow: 'School & Community Support',
                  title: 'Explore local safety infrastructure',
                  description: 'Search for a school, inspect mapped walking and cycling infrastructure, compare routes, or select a point to report a concern.',
                  icon: Icons.travel_explore,
                  trailing: StatusPill(
                    label: 'OpenStreetMap • Overpass',
                    icon: Icons.public,
                  ),
                ),
                const SizedBox(height: 24),
                SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.manage_search, color: colors.primary),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Find your school or community',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                Text(
                                  'Choose a state, then search by school name, city, ZIP code, or district.',
                                  style: TextStyle(
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final stackFields = constraints.maxWidth < 720;
                          final stateWidth = stackFields
                              ? constraints.maxWidth
                              : 245.0;
                          final searchWidth = stackFields
                              ? constraints.maxWidth
                              : math.min(500.0, constraints.maxWidth - 257);
                          return Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              SizedBox(
                                width: stateWidth,
                                child: DropdownButtonFormField<int>(
                                  initialValue: _selectedStateFips,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: 'State',
                                    prefixIcon: Icon(Icons.public),
                                  ),
                                  items: [
                                    for (final state in usStates)
                                      DropdownMenuItem(
                                        value: state.fips,
                                        child: Text(
                                          '${state.code} — ${state.name}',
                                        ),
                                      ),
                                  ],
                                  onChanged: _selectState,
                                ),
                              ),
                              SizedBox(
                                width: searchWidth,
                                child: TextField(
                                  controller: _schoolSearchController,
                                  onChanged: (_) => setState(() {}),
                                  decoration: InputDecoration(
                                    labelText: 'Search schools and communities',
                                    hintText: 'School, city, ZIP, or district',
                                    prefixIcon: const Icon(Icons.search),
                                    suffixIcon:
                                        _schoolSearchController.text.isNotEmpty
                                        ? IconButton(
                                            tooltip: 'Clear school search',
                                            onPressed: () {
                                              _schoolSearchController.clear();
                                              setState(() {});
                                            },
                                            icon: const Icon(Icons.clear),
                                          )
                                        : null,
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                      if (_schoolSearchController.text.trim().isNotEmpty) ...[
                        const SizedBox(height: 12),
                        if (_loadingSchools)
                          const LinearProgressIndicator()
                        else if (searchResults.isEmpty)
                          Text(
                            'No matching public schools found in the selected state.',
                            style: TextStyle(color: colors.onSurfaceVariant),
                          )
                        else
                          Container(
                            constraints: const BoxConstraints(maxHeight: 320),
                            decoration: BoxDecoration(
                              border: Border.all(color: colors.outlineVariant),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: ListView.separated(
                              shrinkWrap: true,
                              itemCount: searchResults.length,
                              separatorBuilder: (_, _) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final school = searchResults[index];
                                return ListTile(
                                  leading: const Icon(Icons.school_outlined),
                                  title: Text(school.name),
                                  subtitle: Text(
                                    '${school.city}, ${school.state} ${school.zipCode} • ${school.district}',
                                  ),
                                  trailing: const Icon(
                                    Icons.center_focus_strong,
                                  ),
                                  onTap: () => _focusSchool(school),
                                );
                              },
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                SectionCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
                        child: Wrap(
                          spacing: 16,
                          runSpacing: 10,
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 560),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Community map',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge,
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    'Tap anywhere to select a report or route point',
                                    style: TextStyle(
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            StatusPill(
                              label: _zoom < _infrastructureZoom
                                  ? 'Zoom in for nearby features'
                                  : '${visibleSchools.length} nearby schools',
                              icon: Icons.school_outlined,
                              backgroundColor: colors.primaryContainer,
                              foregroundColor: colors.onPrimaryContainer,
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
                        child: MapLayerControls(
                          visibleLayers: _visibleLayers,
                          featureCounts: featureCounts,
                          loading: _loadingInfrastructure,
                          zoom: _zoom,
                          error: _infrastructureError,
                          onRetry: _infrastructureError == null
                              ? null
                              : _retryInfrastructure,
                          onLayerChanged: (layer, visible) {
                            setState(() {
                              if (visible) {
                                _visibleLayers.add(layer);
                              } else {
                                _visibleLayers.remove(layer);
                              }
                            });
                          },
                        ),
                      ),
                      Container(
                        height: compactLayout ? 360 : 420,
                        decoration: BoxDecoration(
                          color: colors.surfaceContainer,
                          border: Border.all(
                            color:
                                widget.enableKeyboardNavigation && _mapHasFocus
                                ? colors.primary
                                : colors.outlineVariant,
                            width:
                                widget.enableKeyboardNavigation && _mapHasFocus
                                ? 3
                                : 1,
                          ),
                        ),
                        child: CallbackShortcuts(
                          bindings: {
                            if (widget.enableKeyboardNavigation) ...{
                              const SingleActivator(
                                LogicalKeyboardKey.add,
                              ): () =>
                                  _zoomBy(1),
                              const SingleActivator(
                                LogicalKeyboardKey.equal,
                              ): () =>
                                  _zoomBy(1),
                              const SingleActivator(
                                LogicalKeyboardKey.numpadAdd,
                              ): () =>
                                  _zoomBy(1),
                              const SingleActivator(
                                LogicalKeyboardKey.minus,
                              ): () =>
                                  _zoomBy(-1),
                              const SingleActivator(
                                LogicalKeyboardKey.numpadSubtract,
                              ): () =>
                                  _zoomBy(-1),
                              const SingleActivator(
                                LogicalKeyboardKey.arrowUp,
                              ): () =>
                                  _panMap(0, 1),
                              const SingleActivator(
                                LogicalKeyboardKey.arrowDown,
                              ): () =>
                                  _panMap(0, -1),
                              const SingleActivator(
                                LogicalKeyboardKey.arrowLeft,
                              ): () =>
                                  _panMap(-1, 0),
                              const SingleActivator(
                                LogicalKeyboardKey.arrowRight,
                              ): () =>
                                  _panMap(1, 0),
                            },
                          },
                          child: Focus(
                            focusNode: _mapFocusNode,
                            canRequestFocus: widget.enableKeyboardNavigation,
                            onFocusChange: (focused) =>
                                setState(() => _mapHasFocus = focused),
                            child: Semantics(
                              container: true,
                              label:
                                  'Interactive community map. ${visibleSchools.length} schools and ${visibleReports.length} hazard reports are visible.',
                              hint: widget.enableKeyboardNavigation
                                  ? 'Use arrow keys to pan and plus or minus to zoom.'
                                  : 'Use the map controls to pan and zoom.',
                              child: Stack(
                                children: [
                                  FlutterMap(
                                    mapController: _controller,
                                    options: MapOptions(
                                      initialCenter: PilotSchool.location,
                                      initialZoom: 15,
                                      minZoom: _minZoom,
                                      maxZoom: _maxZoom,
                                      onMapReady: () {
                                        _handleCameraChanged(
                                          _controller.camera,
                                        );
                                      },
                                      onPositionChanged: (camera, _) {
                                        _handleCameraChanged(camera);
                                      },
                                      onTap: (_, location) {
                                        if (widget.enableKeyboardNavigation) {
                                          _mapFocusNode.requestFocus();
                                        }
                                        setState(
                                          () => _selectedPoint = location,
                                        );
                                        widget.onSelectLocation(
                                          location.latitude,
                                          location.longitude,
                                        );
                                      },
                                    ),
                                    children: [
                                      if (widget.enableMapTiles)
                                        TileLayer(
                                          urlTemplate: _tileUrl,
                                          userAgentPackageName:
                                              'org.saferoutes.cac',
                                        ),
                                      if (_visibleLayers.contains(
                                        MapLayer.sidewalks,
                                      ))
                                        PolylineLayer(
                                          key: const ValueKey('sidewalk-layer'),
                                          polylines: [
                                            for (final feature in _features(
                                              InfrastructureType.sidewalk,
                                            ))
                                              Polyline(
                                                points: feature.points,
                                                strokeWidth: 5,
                                                color: MapLayerStyle.sidewalk,
                                                borderStrokeWidth: 2,
                                                borderColor: Colors.white,
                                              ),
                                          ],
                                        ),
                                      if (_visibleLayers.contains(
                                        MapLayer.bikePaths,
                                      ))
                                        PolylineLayer(
                                          key: const ValueKey(
                                            'bike-path-layer',
                                          ),
                                          polylines: [
                                            for (final feature in _features(
                                              InfrastructureType.bikePath,
                                            ))
                                              Polyline(
                                                points: feature.points,
                                                strokeWidth: 6,
                                                color: MapLayerStyle.bikePath,
                                                borderStrokeWidth: 2,
                                                borderColor: Colors.white,
                                              ),
                                          ],
                                        ),
                                      if (_visibleLayers.contains(
                                        MapLayer.bikeLanes,
                                      ))
                                        PolylineLayer(
                                          key: const ValueKey(
                                            'bike-lane-layer',
                                          ),
                                          polylines: [
                                            for (final feature in _features(
                                              InfrastructureType.bikeLane,
                                            ))
                                              Polyline(
                                                points: feature.points,
                                                strokeWidth: 5,
                                                color: MapLayerStyle.bikeLane,
                                                borderStrokeWidth: 2,
                                                borderColor: Colors.white,
                                                pattern: StrokePattern.dashed(
                                                  segments: const [10, 7],
                                                ),
                                              ),
                                          ],
                                        ),
                                      if (_routeAvoidLocations.isNotEmpty &&
                                          _visibleLayers.contains(
                                            MapLayer.hazards,
                                          ))
                                        CircleLayer(
                                          key: const ValueKey(
                                            'hazard-avoidance-layer',
                                          ),
                                          circles: [
                                            for (final location
                                                in _routeAvoidLocations)
                                              CircleMarker(
                                                point: location,
                                                radius: HazardAvoidanceService
                                                    .radiusMeters,
                                                useRadiusInMeter: true,
                                                color: const Color(0x24C4473A),
                                                borderColor: const Color(
                                                  0xFFC4473A,
                                                ),
                                                borderStrokeWidth: 2,
                                              ),
                                          ],
                                        ),
                                      if (_routeAssessments.isNotEmpty)
                                        PolylineLayer(
                                          key: const ValueKey('route-layer'),
                                          polylines: [
                                            for (final assessment
                                                in _routeAssessments)
                                              Polyline(
                                                points: assessment.route.points,
                                                strokeWidth:
                                                    _selectedRouteId ==
                                                        assessment.route.id
                                                    ? 7
                                                    : 4,
                                                color:
                                                    assessment.route.profile ==
                                                        RouteProfile.walking
                                                    ? const Color(0xFF6A45A5)
                                                    : const Color(0xFF126C9C),
                                                borderStrokeWidth: 2,
                                                borderColor: Colors.white,
                                              ),
                                          ],
                                        ),
                                      MarkerLayer(markers: markers),
                                    ],
                                  ),
                                  Positioned(
                                    left: 12,
                                    top: 12,
                                    child: StatusPill(
                                      label: widget.isLive
                                          ? 'PILOT DATABASE'
                                          : 'SUPABASE NOT CONFIGURED',
                                      icon: Icons.info_outline,
                                      backgroundColor: Colors.white.withValues(
                                        alpha: .94,
                                      ),
                                      foregroundColor: const Color(0xFF604300),
                                    ),
                                  ),
                                  Positioned(
                                    right: 12,
                                    top: 12,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(13),
                                        boxShadow: const [
                                          BoxShadow(
                                            color: Color(0x22000000),
                                            blurRadius: 10,
                                            offset: Offset(0, 3),
                                          ),
                                        ],
                                      ),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            tooltip: 'Zoom in',
                                            onPressed: () => _zoomBy(1),
                                            icon: const Icon(Icons.add),
                                          ),
                                          const Divider(height: 1),
                                          IconButton(
                                            tooltip: 'Zoom out',
                                            onPressed: () => _zoomBy(-1),
                                            icon: const Icon(Icons.remove),
                                          ),
                                          const Divider(height: 1),
                                          IconButton(
                                            tooltip: 'Go to my location',
                                            onPressed: _findingLocation
                                                ? null
                                                : _findCurrentLocation,
                                            icon: _findingLocation
                                                ? const SizedBox.square(
                                                    dimension: 20,
                                                    child:
                                                        CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                        ),
                                                  )
                                                : const Icon(Icons.my_location),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  if (_loadingSchools)
                                    const Positioned(
                                      left: 0,
                                      right: 0,
                                      top: 0,
                                      child: LinearProgressIndicator(),
                                    ),
                                  if (_schoolError != null)
                                    Positioned(
                                      left: 12,
                                      bottom: 28,
                                      child: Material(
                                        color: colors.errorContainer,
                                        borderRadius: BorderRadius.circular(8),
                                        child: Padding(
                                          padding: const EdgeInsets.all(8),
                                          child: Text(_schoolError!),
                                        ),
                                      ),
                                    ),
                                  Positioned(
                                    right: 5,
                                    bottom: 4,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(
                                          alpha: .9,
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 5,
                                          vertical: 3,
                                        ),
                                        child: ConstrainedBox(
                                          constraints: BoxConstraints(
                                            maxWidth: compactLayout ? 260 : 520,
                                          ),
                                          child: const Text(
                                            '© OpenStreetMap contributors • Infrastructure via Overpass API\nSchools search: Urban Institute / NCES CCD',
                                            textAlign: TextAlign.right,
                                            style: TextStyle(
                                              fontSize: 10,
                                              height: 1.25,
                                              color: Colors.black87,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(18),
                        child: _selectedPoint != null
                            ? _SelectedLocation(
                                selected: _selectedPoint!,
                                onReport: () => widget.onReportAt(
                                  _selectedPoint!.latitude,
                                  _selectedPoint!.longitude,
                                ),
                              )
                            : const _TapMapHint(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                if (widget.showMapTextAlternative) ...[
                  _MapTextAlternative(
                    schools: visibleSchools,
                    reports: visibleReports,
                    selectedPoint: _selectedPoint,
                    infrastructure: _infrastructure,
                  ),
                  const SizedBox(height: 18),
                ],
                RoutePlannerPanel(
                  selectedPoint: _selectedPoint,
                  origin: _routeOrigin,
                  destination: _routeDestination,
                  configured: _routeService.isConfigured,
                  loading: _loadingRoutes,
                  assessments: _routeAssessments,
                  selectedRouteId: _selectedRouteId,
                  error: _routeError,
                  onUseAsOrigin: _useSelectedAsRouteOrigin,
                  onUseAsDestination: _useSelectedAsRouteDestination,
                  onCompare: _compareRoutes,
                  onClear: _clearRoute,
                  onSelectRoute: _fitRoute,
                ),
                const SizedBox(height: 18),
                SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 10,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Icon(Icons.tune, color: colors.primary),
                          Text(
                            'Filter map markers',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ChoiceChip(
                            label: const Text('All issues'),
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
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                const _SafetyNotice(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MapTextAlternative extends StatelessWidget {
  const _MapTextAlternative({
    required this.schools,
    required this.reports,
    required this.selectedPoint,
    required this.infrastructure,
  });

  final List<OsmMapFeature> schools;
  final List<HazardReport> reports;
  final LatLng? selectedPoint;
  final InfrastructureSnapshot? infrastructure;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const displayLimit = 8;
    return SectionCard(
      child: ExpansionTile(
        initiallyExpanded: true,
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        leading: Icon(Icons.list_alt_outlined, color: colors.primary),
        title: Text(
          'Map information in text',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        subtitle: Text(
          '${schools.length} schools and ${reports.length} hazard reports currently visible',
        ),
        children: [
          if (selectedPoint case final point?)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.location_on_outlined),
              title: const Text('Selected report location'),
              subtitle: Text(
                '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}',
              ),
            ),
          if (schools.isEmpty && reports.isEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  'No school or hazard markers are visible. Zoom in or choose another state.',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ),
            ),
          const _TextMapHeading(
            'OpenStreetMap infrastructure in the loaded area',
          ),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(
              Icons.linear_scale,
              color: MapLayerStyle.sidewalk,
            ),
            title: const Text('Sidewalks'),
            subtitle: Text(
              '${infrastructure?.count(MapLayer.sidewalks) ?? 0} mapped features. Missing data means unknown, not unsafe.',
            ),
          ),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(
              Icons.directions_walk,
              color: MapLayerStyle.crossing,
            ),
            title: const Text('Crossings'),
            subtitle: Text(
              '${infrastructure?.count(MapLayer.crossings) ?? 0} mapped features.',
            ),
          ),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(
              Icons.route_outlined,
              color: MapLayerStyle.bikePath,
            ),
            title: const Text('Bike paths and lanes'),
            subtitle: Text(
              '${infrastructure?.count(MapLayer.bikePaths) ?? 0} paths and ${infrastructure?.count(MapLayer.bikeLanes) ?? 0} lanes mapped.',
            ),
          ),
          if (schools.isNotEmpty) ...[
            const _TextMapHeading('Schools in view'),
            for (final school in schools.take(displayLimit))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.school_outlined),
                title: Text(school.name),
                subtitle: Text(
                  school.tags['operator'] ??
                      school.tags['addr:street'] ??
                      'OpenStreetMap feature',
                ),
              ),
            if (schools.length > displayLimit)
              Text(
                '${schools.length - displayLimit} more schools are visible. Zoom in or use school search to narrow the list.',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
          ],
          if (reports.isNotEmpty) ...[
            const _TextMapHeading('Hazard reports in view'),
            for (final report in reports.take(displayLimit))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.warning_amber_rounded),
                title: Text('${report.type.label} • ${report.status.label}'),
                subtitle: Text(
                  'Severity ${report.severity} of 5. ${report.description}',
                ),
              ),
            if (reports.length > displayLimit)
              Text(
                '${reports.length - displayLimit} more reports are visible. Use the hazard filters to narrow the list.',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
          ],
        ],
      ),
    );
  }
}

class _TextMapHeading extends StatelessWidget {
  const _TextMapHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 4),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    ),
  );
}

class _SelectedLocation extends StatelessWidget {
  const _SelectedLocation({required this.selected, required this.onReport});

  final LatLng selected;
  final VoidCallback onReport;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 16,
      runSpacing: 14,
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(Icons.location_on, color: colors.primary),
            ),
            const SizedBox(width: 13),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Selected map location',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(
                  '${selected.latitude.toStringAsFixed(5)}, '
                  '${selected.longitude.toStringAsFixed(5)}',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ],
        ),
        FilledButton.icon(
          onPressed: onReport,
          icon: const Icon(Icons.add_location_alt_outlined),
          label: const Text('Report this location'),
        ),
      ],
    );
  }
}

class _TapMapHint extends StatelessWidget {
  const _TapMapHint();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(Icons.touch_app_outlined, color: colors.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Tap anywhere on the map',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              Text(
                'Choose a precise point before creating a report.',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SafetyNotice extends StatelessWidget {
  const _SafetyNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7E8),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFF1D9A7)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined, color: Color(0xFF795300)),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Not a verified safety map',
                  style: TextStyle(
                    color: Color(0xFF604300),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Infrastructure comes from OpenStreetMap and may be incomplete or outdated; missing features are unknown, not unsafe. Community reports retain their displayed review status. Route scores are a transparent comparison aid, not a safety guarantee.',
                  style: TextStyle(color: Color(0xFF795E25), height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

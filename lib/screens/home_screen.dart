import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/accessibility_preferences.dart';
import '../models/hazard_photo.dart';
import '../models/hazard_report.dart';
import '../services/supabase_hazard_repository.dart';
import 'accessibility_settings_dialog.dart';
import 'analytics_screen.dart';
import 'explore_screen.dart';
import 'report_form_screen.dart';
import 'reports_screen.dart';
import 'community_screen.dart';
import 'community_review_dialog.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.enableMapTiles = true,
    this.liveClient,
    this.enableLiveUpdates = true,
    this.environmentName = 'production',
    required this.accessibilityPreferences,
    required this.onAccessibilityPreferencesChanged,
  });

  final bool enableMapTiles;
  final SupabaseClient? liveClient;
  final bool enableLiveUpdates;
  final String environmentName;
  final AccessibilityPreferences accessibilityPreferences;
  final ValueChanged<AccessibilityPreferences>
  onAccessibilityPreferencesChanged;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;
  late List<HazardReport> _reports;
  Timer? _reportChangesDebounce;
  double? _selectedLatitude;
  double? _selectedLongitude;
  bool _loading = false;
  String? _loadError;
  int _refreshVersion = 0;
  int _visibilityVersion = 0;

  bool get _live => widget.liveClient != null;

  @override
  void initState() {
    super.initState();
    _reports = [];
    if (widget.liveClient case final client?) {
      if (widget.enableLiveUpdates) {
        void changed(PostgresChangePayload _) {
          _reportChangesDebounce?.cancel();
          _reportChangesDebounce = Timer(const Duration(milliseconds: 450), () {
            if (mounted) unawaited(_refreshReports());
          });
        }

        client
            .channel('home-community-reports')
            .onPostgresChanges(
              event: PostgresChangeEvent.all,
              schema: 'public',
              table: 'hazard_reports',
              callback: changed,
            )
            .onPostgresChanges(
              event: PostgresChangeEvent.all,
              schema: 'public',
              table: 'community_review_totals',
              callback: changed,
            )
            .subscribe();
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_refreshReports());
      });
    }
  }

  @override
  void dispose() {
    _reportChangesDebounce?.cancel();
    super.dispose();
  }

  Future<void> _refreshReports() async {
    final client = widget.liveClient;
    if (client == null) return;
    final version = ++_refreshVersion;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final loaded = await SupabaseHazardRepository(client).fetchHazards();
      if (mounted && version == _refreshVersion) {
        final visible = {for (final r in loaded) r.id: r.status};
        final withdrawnOrChanged = _reports.any(
          (r) => visible[r.id] != r.status,
        );
        setState(() {
          if (withdrawnOrChanged) _visibilityVersion++;
          _reports = loaded;
        });
      }
    } catch (_) {
      if (mounted && version == _refreshVersion) {
        setState(
          () => _loadError = 'Public reports are unavailable. Retry shortly.',
        );
      }
    } finally {
      if (mounted && version == _refreshVersion) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _reviewReport(HazardReport report) async {
    final client = widget.liveClient;
    if (client == null) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CommunityReviewDialog(
        client: client,
        report: report,
        onChanged: (saved) {
          if (!mounted) return;
          setState(() {
            _refreshVersion++;
            _visibilityVersion++;
            _loading = false;
            _reports = [..._reports.map((r) => r.id == saved.id ? saved : r)];
          });
        },
      ),
    );
    if (mounted) await _refreshReports();
  }

  // The map selection is shared across tabs. Selecting a map point must
  // survive navigation even if the user taps the Report tab directly.
  void _selectLocation(double latitude, double longitude) {
    setState(() {
      _selectedLatitude = latitude;
      _selectedLongitude = longitude;
    });
  }

  void _startReport(double latitude, double longitude) {
    setState(() {
      _selectedLatitude = latitude;
      _selectedLongitude = longitude;
      _selectedIndex = 3;
    });
  }

  Future<void> _saveReport(
    HazardReport report,
    HazardPhotoDraft? photo,
    ValueChanged<double> onProgress,
  ) async {
    final client = widget.liveClient;
    if (client == null) {
      throw StateError(
        'Supabase is not configured. Start with SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY.',
      );
    }
    final saved = await SupabaseHazardRepository(client)
        .submitHazard(report, photo: photo, onProgress: onProgress);
    if (!mounted) return;
    setState(() {
      _refreshVersion++;
      _reports = [saved, ..._reports];
      _selectedLatitude = null;
      _selectedLongitude = null;
      _selectedIndex = 0;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Report shared for community review.')),
    );
  }

  Future<void> _showAccessibilitySettings() async {
    final selected = await showDialog<AccessibilityPreferences>(
      context: context,
      builder: (_) => AccessibilitySettingsDialog(
        initialPreferences: widget.accessibilityPreferences,
      ),
    );
    if (selected != null) {
      widget.onAccessibilityPreferencesChanged(selected);
    }
  }

  void _selectTab(int index) {
    setState(() => _selectedIndex = index);
    if (index == 1 || index == 4) unawaited(_refreshReports());
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      ExploreScreen(
        reports: _reports,
        liveClient: widget.liveClient,
        onReportAt: _startReport,
        onSelectLocation: _selectLocation,
        enableMapTiles: widget.enableMapTiles,
        visibilityVersion: _visibilityVersion,
        isLive: _live,
        showMapTextAlternative: widget.accessibilityPreferences.showMapText,
        enableKeyboardNavigation:
            widget.accessibilityPreferences.keyboardMapNavigation,
      ),
      ReportsScreen(reports: _reports, isLive: _live, onReview: _reviewReport),
      AnalyticsScreen(
        client: widget.liveClient,
        isActive: _selectedIndex == 2,
        enableMapTiles: widget.enableMapTiles,
        refreshVersion: _refreshVersion,
        visibilityVersion: _visibilityVersion,
      ),
      ReportFormScreen(
        lookupSchools: widget.liveClient == null
            ? null
            : SupabaseHazardRepository(widget.liveClient!).findNearbySchools,
        onSubmit: _saveReport,
        onChooseLocation: () => setState(() => _selectedIndex = 0),
        selectedLatitude: _selectedLatitude,
        selectedLongitude: _selectedLongitude,
        isLive: _live,
        submissionEnabled: _live,
      ),
      CommunityScreen(
        reports: _reports,
        client: widget.liveClient,
        onReview: _reviewReport,
        refreshVersion: _refreshVersion,
      ),
    ];

    final destinations = <NavigationDestination>[
      const NavigationDestination(
        icon: Icon(Icons.map_outlined),
        selectedIcon: Icon(Icons.map),
        label: 'Explore',
      ),
      const NavigationDestination(
        icon: Icon(Icons.list_alt_outlined),
        selectedIcon: Icon(Icons.list_alt),
        label: 'Reports',
      ),
      const NavigationDestination(
        icon: Icon(Icons.analytics_outlined),
        selectedIcon: Icon(Icons.analytics),
        label: 'Analytics',
      ),
      const NavigationDestination(
        icon: Icon(Icons.add_circle_outline),
        selectedIcon: Icon(Icons.add_circle),
        label: 'Report',
      ),
      const NavigationDestination(
        icon: Icon(Icons.fact_check_outlined),
        selectedIcon: Icon(Icons.fact_check),
        label: 'Community',
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 68,
        leadingWidth: 68,
        leading: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              borderRadius: BorderRadius.circular(13),
            ),
            child: const Icon(Icons.route, color: Colors.white),
          ),
        ),
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('SafeRoutes'),
            Text(
              'Community-powered safer travel',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
            ),
          ],
        ),
        actions: [
          if (_live)
            IconButton(
              tooltip: 'Refresh reports',
              onPressed: _loading ? null : _refreshReports,
              icon: const Icon(Icons.refresh),
            ),
          IconButton(
            tooltip: 'Accessibility settings',
            onPressed: _showAccessibilitySettings,
            icon: Icon(
              Icons.accessibility_new,
              color: widget.accessibilityPreferences.hasEnabledChoices
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final useRail = constraints.maxWidth >= 900;
          final content = Column(
            children: [
              if (_loading) const LinearProgressIndicator(),
              if (_loadError != null)
                MaterialBanner(
                  content: Text(_loadError!),
                  actions: [
                    TextButton(
                      onPressed: _refreshReports,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              Expanded(
                child: IndexedStack(index: _selectedIndex, children: screens),
              ),
            ],
          );

          if (!useRail) return SafeArea(top: false, child: content);

          return Row(
            children: [
              Container(
                width: 220,
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border(
                    right: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                ),
                child: NavigationRail(
                  extended: true,
                  backgroundColor: Colors.transparent,
                  selectedIndex: _selectedIndex,
                  onDestinationSelected: _selectTab,
                  groupAlignment: -0.82,
                  useIndicator: true,
                  labelType: NavigationRailLabelType.none,
                  leading: Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      'WORKSPACE',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  destinations: [
                    for (final item in destinations)
                      NavigationRailDestination(
                        icon: item.icon,
                        selectedIcon: item.selectedIcon,
                        label: Text(item.label),
                      ),
                  ],
                ),
              ),
              Expanded(child: SafeArea(top: false, child: content)),
            ],
          );
        },
      ),
      bottomNavigationBar: MediaQuery.sizeOf(context).width < 900
          ? NavigationBar(
              selectedIndex: _selectedIndex,
              onDestinationSelected: _selectTab,
              destinations: destinations,
            )
          : null,
    );
  }
}

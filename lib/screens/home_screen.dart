import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/pilot_school.dart';
import '../models/accessibility_preferences.dart';
import '../models/hazard_photo.dart';
import '../models/hazard_report.dart';
import '../models/report_moderation.dart';
import '../services/supabase_hazard_repository.dart';
import 'accessibility_settings_dialog.dart';
import 'analytics_screen.dart';
import 'auth_dialog.dart';
import 'explore_screen.dart';
import 'report_form_screen.dart';
import 'reports_screen.dart';
import 'moderation_screen.dart';
import 'report_review_dialog.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.enableMapTiles = true,
    this.liveClient,
    required this.accessibilityPreferences,
    required this.onAccessibilityPreferencesChanged,
  });

  final bool enableMapTiles;
  final SupabaseClient? liveClient;
  final AccessibilityPreferences accessibilityPreferences;
  final ValueChanged<AccessibilityPreferences>
  onAccessibilityPreferencesChanged;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;
  late List<HazardReport> _reports;
  StreamSubscription<AuthState>? _authSubscription;
  double? _selectedLatitude;
  double? _selectedLongitude;
  bool _loading = false;
  String? _loadError;
  List<ReportFlag> _flags = [];
  bool _canModerate = false;
  int _refreshVersion = 0;
  String? _loadedUserId;
  BuildContext? _reviewContext;

  bool get _live => widget.liveClient != null;

  @override
  void initState() {
    super.initState();
    _reports = [];
    _canModerate = false;
    if (widget.liveClient case final client?) {
      _authSubscription = client.auth.onAuthStateChange.listen((_) {
        unawaited(_refreshReports());
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_refreshReports());
      });
    }
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  Future<void> _refreshReports() async {
    final client = widget.liveClient;
    if (client == null) return;
    final version = ++_refreshVersion;
    final userId = client.auth.currentUser?.id;
    if (_loadedUserId != userId) {
      if (_reviewContext case final reviewContext? when reviewContext.mounted) {
        Navigator.of(reviewContext).pop();
      }
      _loadedUserId = userId;
      _reports = [];
      _flags = [];
      _canModerate = false;
      if (_selectedIndex == 4) _selectedIndex = 1;
    }
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final repository = SupabaseHazardRepository(client);
      final loaded = await repository.fetchHazards();
      final canModerate = await repository.canModerate();
      final flags = await repository.fetchFlags(PilotSchool.id);
      if (mounted && version == _refreshVersion) {
        setState(() {
          _reports = loaded;
          _flags = flags;
          _canModerate = canModerate;
          if (!canModerate && _selectedIndex == 4) _selectedIndex = 1;
        });
      }
    } catch (error) {
      if (mounted && version == _refreshVersion) {
        setState(() {
          _loadError = 'Database connection failed: $error';
          _reports = [];
          _flags = [];
          _canModerate = false;
          if (_selectedIndex == 4) _selectedIndex = 1;
        });
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
    final actorId = client.auth.currentUser?.id;
    final canViewHistory =
        _canModerate || report.reporterId == actorId && actorId != null;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        _reviewContext = dialogContext;
        return ReportReviewDialog(
          report: report,
          canViewHistory: canViewHistory,
          loadData: () async {
            final repository = SupabaseHazardRepository(client);
            final flags = await repository.fetchFlags(report.schoolId);
            return ReportReviewData(
              flags: flags.where((f) => f.reportId == report.id).toList(),
              history: await repository.fetchHistory(report.id),
            );
          },
          onFlag:
              actorId != null &&
                  (report.status == ReportStatus.unverified ||
                      report.status == ReportStatus.verified)
              ? (reason) => _flagReport(report, reason, actorId)
              : null,
          onModerate: _canModerate
              ? (status, reason) =>
                    _moderateReport(report, status, reason, actorId!)
              : null,
          onDelete:
              actorId != null && (_canModerate || report.reporterId == actorId)
              ? () => _deleteReport(report, actorId)
              : null,
        );
      },
    );
    _reviewContext = null;
  }

  Future<void> _flagReport(
    HazardReport report,
    String reason,
    String actorId,
  ) async {
    if (_flags.any((f) => f.reportId == report.id && f.userId == actorId)) {
      throw StateError('You have already flagged this report.');
    }
    final client = widget.liveClient;
    if (client == null) return;
    if (client.auth.currentUser?.id != actorId) {
      throw StateError('Your account changed. Reopen this report.');
    }
    await SupabaseHazardRepository(client).flagReport(report, reason);
    if (!mounted || client.auth.currentUser?.id != actorId) {
      return;
    }
    setState(() {
      // A refresh started before this write must not replace the new flag.
      _refreshVersion++;
      _loading = false;
      _flags.insert(
        0,
        ReportFlag(
          reportId: report.id,
          userId: actorId,
          reason: reason,
          createdAt: DateTime.now(),
        ),
      );
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Accuracy flag submitted for moderator review.')),
    );
  }

  Future<void> _moderateReport(
    HazardReport report,
    ReportStatus status,
    String reason,
    String actorId,
  ) async {
    final client = widget.liveClient;
    if (client == null) return;
    if (client.auth.currentUser?.id != actorId) {
      throw StateError('Your account changed. Reopen this report.');
    }
    final saved = await SupabaseHazardRepository(client)
        .moderateReport(report, status, reason);
    if (!mounted || client.auth.currentUser?.id != actorId) {
      return;
    }
    final now = DateTime.now();
    setState(() {
      // Discard refreshes that captured the report before this decision.
      _refreshVersion++;
      _loading = false;
      _reports = _reports.map((r) => r.id == saved.id ? saved : r).toList();
      _flags = _flags
          .map((f) => f.reportId == saved.id ? f.reviewed(now) : f)
          .toList();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Report ${status.label.toLowerCase()}. Decision recorded.',
        ),
      ),
    );
  }

  Future<void> _deleteReport(HazardReport report, String actorId) async {
    final client = widget.liveClient;
    if (client == null) return;
    if (client.auth.currentUser?.id != actorId) {
      throw StateError('Your account changed. Reopen this report.');
    }
    await SupabaseHazardRepository(client).deleteHazard(report);
    if (!mounted || client.auth.currentUser?.id != actorId) return;
    setState(() {
      _refreshVersion++;
      _reports.removeWhere((candidate) => candidate.id == report.id);
      _flags.removeWhere((flag) => flag.reportId == report.id);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Report and photo evidence deleted.')),
    );
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
      _reports.insert(0, saved);
      _selectedLatitude = null;
      _selectedLongitude = null;
      _selectedIndex = 0;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Test report saved to Supabase as unverified.'),
      ),
    );
  }

  Future<void> _showAccount() async {
    final client = widget.liveClient;
    if (client == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AuthDialog(client: client),
    );
    if (mounted) await _refreshReports();
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

  @override
  Widget build(BuildContext context) {
    final screens = [
      ExploreScreen(
        reports: _reports,
        onReportAt: _startReport,
        onSelectLocation: _selectLocation,
        enableMapTiles: widget.enableMapTiles,
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
      ),
      ReportFormScreen(
        onSubmit: _saveReport,
        onChooseLocation: () => setState(() => _selectedIndex = 0),
        selectedLatitude: _selectedLatitude,
        selectedLongitude: _selectedLongitude,
        isLive: _live,
        submissionEnabled: _live,
      ),
      if (_canModerate)
        ModerationScreen(
          reports: _reports,
          flags: _flags,
          onReview: _reviewReport,
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
      if (_canModerate)
        const NavigationDestination(
          icon: Icon(Icons.fact_check_outlined),
          selectedIcon: Icon(Icons.fact_check),
          label: 'Moderation',
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
          if (_live)
            IconButton(
              tooltip: widget.liveClient!.auth.currentUser == null
                  ? 'Sign in to SafeRoutes'
                  : 'SafeRoutes account',
              onPressed: _showAccount,
              icon: Icon(
                widget.liveClient!.auth.currentUser == null
                    ? Icons.login
                    : Icons.account_circle_outlined,
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF1D6),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: const Color(0xFFF5D495)),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.science_outlined,
                      size: 14,
                      color: Color(0xFF8A5A00),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _live ? 'PILOT DATABASE' : 'PROTOTYPE',
                      style: const TextStyle(
                        color: Color(0xFF704900),
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: .6,
                      ),
                    ),
                  ],
                ),
              ),
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
                  onDestinationSelected: (index) =>
                      setState(() => _selectedIndex = index),
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
              onDestinationSelected: (index) =>
                  setState(() => _selectedIndex = index),
              destinations: destinations,
            )
          : null,
    );
  }
}

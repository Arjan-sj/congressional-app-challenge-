import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  StreamSubscription<AuthState>? _authSubscription;
  Timer? _reportChangesDebounce;
  Timer? _membershipPoll;
  bool _checkingPrivileges = false;
  double? _selectedLatitude;
  double? _selectedLongitude;
  bool _loading = false;
  String? _loadError;
  List<ReportFlag> _flags = [];
  bool _canModerate = false;
  int _refreshVersion = 0;
  int _visibilityVersion = 0;
  String? _loadedUserId;
  BuildContext? _reviewContext;

  bool get _live => widget.liveClient != null;

  @override
  void initState() {
    super.initState();
    _reports = [];
    _canModerate = false;
    if (widget.liveClient case final client?) {
      if (widget.enableLiveUpdates) {
        _membershipPoll = Timer.periodic(
          const Duration(seconds: 20),
          (_) => _refreshPrivileges(),
        );
        client
            .channel('home-report-associations')
            .onPostgresChanges(
              event: PostgresChangeEvent.all,
              schema: 'public',
              table: 'hazard_reports',
              callback: (_) {
                _reportChangesDebounce?.cancel();
                _reportChangesDebounce = Timer(
                  const Duration(milliseconds: 450),
                  () {
                    if (mounted) unawaited(_refreshReports());
                  },
                );
              },
            )
            .subscribe();
      }
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
    _reportChangesDebounce?.cancel();
    _membershipPoll?.cancel();
    super.dispose();
  }

  void _clearModeratorAccess() {
    if (!mounted) return;
    if (_reviewContext case final reviewContext? when reviewContext.mounted) {
      Navigator.of(reviewContext).pop();
    }
    _reviewContext = null;
    setState(() {
      _refreshVersion++;
      _visibilityVersion++;
      _canModerate = false;
      _reports = [];
      _flags = [];
      _loading = false;
      if (_selectedIndex == 4) _selectedIndex = 1;
    });
  }

  Future<void> _refreshPrivileges() async {
    final client = widget.liveClient;
    if (client == null ||
        client.auth.currentUser == null ||
        _checkingPrivileges) {
      return;
    }
    _checkingPrivileges = true;
    final actor = client.auth.currentUser!.id;
    try {
      final allowed = await SupabaseHazardRepository(client)
          .canModerate()
          .timeout(const Duration(seconds: 10));
      if (!mounted || client.auth.currentUser?.id != actor) return;
      if (allowed != _canModerate) {
        if (!allowed) _clearModeratorAccess();
        unawaited(_refreshReports());
      }
    } catch (_) {
      if (mounted && client.auth.currentUser?.id == actor && _canModerate) {
        _clearModeratorAccess();
      }
    } finally {
      _checkingPrivileges = false;
    }
  }

  void _moderationAccessLost() {
    _clearModeratorAccess();
    unawaited(_refreshReports());
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
      _visibilityVersion++;
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
      final initialAccess = await repository.canModerate();
      if (!mounted || version != _refreshVersion) return;
      if (_canModerate && !initialAccess) {
        _clearModeratorAccess();
        unawaited(_refreshReports());
        return;
      }
      final loaded = await repository.fetchHazards();
      final flags = await repository.fetchFlags();
      final canModerate = await repository.canModerate();
      if (!mounted || version != _refreshVersion) return;
      if (initialAccess && !canModerate) {
        _clearModeratorAccess();
        unawaited(_refreshReports());
        return;
      }
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
        if (_canModerate) {
          _clearModeratorAccess();
        }
        setState(() {
          _loadError = 'Database connection failed: $error';
          // Protected moderator data is cleared if privileges cannot be checked.
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
    if (_canModerate && !await SupabaseHazardRepository(client).canModerate()) {
      _moderationAccessLost();
      return;
    }
    if (!mounted || client.auth.currentUser?.id != actorId) return;
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
            final flags = await repository.fetchFlagsForReport(report.id);
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

  Future<void> _reviewModerationReport(HazardReport report) async {
    final client = widget.liveClient;
    if (client == null) return;
    final actorId = client.auth.currentUser?.id;
    try {
      final details = (await SupabaseHazardRepository(
        client,
      ).fetchHazards(reportId: report.id)).firstOrNull;
      if (!mounted || client.auth.currentUser?.id != actorId) return;
      if (details == null) {
        throw StateError('Report is no longer available. Refresh the queue.');
      }
      if (mounted) await _reviewReport(details);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Unable to open report: $error')),
        );
      }
    }
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
    late HazardReport saved;
    try {
      saved = await SupabaseHazardRepository(client)
          .moderateReport(report, status, reason);
    } on PostgrestException catch (error) {
      if (error.code == '42501') _moderationAccessLost();
      rethrow;
    }
    if (!mounted || client.auth.currentUser?.id != actorId) {
      return;
    }
    final now = DateTime.now();
    setState(() {
      // Discard refreshes that captured the report before this decision.
      _refreshVersion++;
      _loading = false;
      _reports = [
        if (!_reports.any((r) => r.id == saved.id)) saved,
        ..._reports.map((r) => r.id == saved.id ? saved : r),
      ];
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
      _reports = _reports
          .where((candidate) => candidate.id != report.id)
          .toList();
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
      _refreshVersion++;
      _reports = [saved, ..._reports];
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
      if (_canModerate)
        ModerationScreen(
          reports: _reports,
          flags: _flags,
          onReview: _reviewModerationReport,
          client: widget.liveClient,
          isActive: _selectedIndex == 4,
          refreshVersion: _refreshVersion,
          onAccessLost: _moderationAccessLost,
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

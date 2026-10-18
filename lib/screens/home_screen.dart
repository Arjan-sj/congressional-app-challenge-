import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/demo_reports.dart';
import '../data/pilot_school.dart';
import '../models/hazard_report.dart';
import '../services/supabase_hazard_repository.dart';
import 'auth_dialog.dart';
import 'explore_screen.dart';
import 'report_form_screen.dart';
import 'reports_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.enableMapTiles = true, this.liveClient});

  final bool enableMapTiles;
  final SupabaseClient? liveClient;

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

  bool get _live => widget.liveClient != null;

  @override
  void initState() {
    super.initState();
    _reports = _live ? [] : buildDemoReports();
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
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final loaded = await SupabaseHazardRepository(client)
          .fetchHazards(PilotSchool.id);
      if (mounted) setState(() => _reports = loaded);
    } catch (error) {
      if (mounted) {
        setState(() => _loadError = 'Database connection failed: $error');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _startReport(double latitude, double longitude) {
    setState(() {
      _selectedLatitude = latitude;
      _selectedLongitude = longitude;
      _selectedIndex = 2;
    });
  }

  Future<void> _saveReport(HazardReport report) async {
    final client = widget.liveClient;
    if (client == null) {
      setState(() {
        _reports.insert(0, report);
        _selectedLatitude = null;
        _selectedLongitude = null;
        _selectedIndex = 0;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Demo saved in memory, not online.')),
      );
      return;
    }
    final saved = await SupabaseHazardRepository(client).submitHazard(report);
    if (!mounted) return;
    setState(() {
      _reports.insert(0, saved);
      _selectedLatitude = null;
      _selectedLongitude = null;
      _selectedIndex = 0;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Test report saved to Supabase as unverified.')),
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

  @override
  Widget build(BuildContext context) {
    final screens = [
      ExploreScreen(
        reports: _reports,
        onReportAt: _startReport,
        enableMapTiles: widget.enableMapTiles,
        isLive: _live,
      ),
      ReportsScreen(reports: _reports, isLive: _live),
      ReportFormScreen(
        onSubmit: _saveReport,
        onChooseLocation: () => setState(() => _selectedIndex = 0),
        selectedLatitude: _selectedLatitude,
        selectedLongitude: _selectedLongitude,
        isLive: _live,
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('SafeRoutes'),
        actions: [
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
            padding: const EdgeInsets.only(right: 12),
            child: Center(child: Text(_live ? 'PILOT DATABASE' : 'PROTOTYPE')),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
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
            Expanded(child: IndexedStack(index: _selectedIndex, children: screens)),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() => _selectedIndex = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'Explore',
          ),
          NavigationDestination(
            icon: Icon(Icons.list_alt_outlined),
            selectedIcon: Icon(Icons.list_alt),
            label: 'Reports',
          ),
          NavigationDestination(
            icon: Icon(Icons.add_circle_outline),
            selectedIcon: Icon(Icons.add_circle),
            label: 'Report',
          ),
        ],
      ),
    );
  }
}

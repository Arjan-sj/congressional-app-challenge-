import 'package:flutter/material.dart';

import '../data/demo_reports.dart';
import '../models/hazard_report.dart';
import 'explore_screen.dart';
import 'report_form_screen.dart';
import 'reports_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.enableMapTiles = true});

  final bool enableMapTiles;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;
  final List<HazardReport> _reports = buildDemoReports();
  double? _selectedLatitude;
  double? _selectedLongitude;

  void _startReport(double latitude, double longitude) {
    setState(() {
      _selectedLatitude = latitude;
      _selectedLongitude = longitude;
      _selectedIndex = 2;
    });
  }

  void _addDemoReport(HazardReport report) {
    setState(() {
      _reports.insert(0, report);
      _selectedLatitude = null;
      _selectedLongitude = null;
      _selectedIndex = 0;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Demo report saved in memory, not online.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      ExploreScreen(
        reports: _reports,
        onReportAt: _startReport,
        enableMapTiles: widget.enableMapTiles,
      ),
      ReportsScreen(reports: _reports),
      ReportFormScreen(
        onSubmit: _addDemoReport,
        onChooseLocation: () => setState(() => _selectedIndex = 0),
        selectedLatitude: _selectedLatitude,
        selectedLongitude: _selectedLongitude,
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('SafeRoutes'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: Text('PROTOTYPE')),
          ),
        ],
      ),
      body: SafeArea(
        child: IndexedStack(index: _selectedIndex, children: screens),
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

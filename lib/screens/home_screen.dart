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
        icon: Icon(Icons.add_circle_outline),
        selectedIcon: Icon(Icons.add_circle),
        label: 'Report',
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
                child: const Row(
                  children: [
                    Icon(
                      Icons.science_outlined,
                      size: 14,
                      color: Color(0xFF8A5A00),
                    ),
                    SizedBox(width: 5),
                    Text(
                      'PROTOTYPE',
                      style: TextStyle(
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
          final content = IndexedStack(
            index: _selectedIndex,
            children: screens,
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

import 'package:flutter/material.dart';

import '../data/demo_reports.dart';
import '../models/hazard_report.dart';
import 'explore_screen.dart';
import 'report_form_screen.dart';
import 'reports_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;
  final List<HazardReport> _reports = buildDemoReports();

  void _addDemoReport(HazardReport report) {
    setState(() {
      _reports.insert(0, report);
      _selectedIndex = 1;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved in this session only — not uploaded.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      ExploreScreen(reports: _reports),
      ReportsScreen(reports: _reports),
      ReportFormScreen(onSubmit: _addDemoReport),
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

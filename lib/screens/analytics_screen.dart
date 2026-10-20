import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AnalyticsBucket;

import '../data/pilot_school.dart';
import '../models/analytics.dart';
import '../models/hazard_report.dart';
import '../services/analytics_export_service.dart';
import '../services/analytics_repository.dart';
import '../widgets/app_ui.dart';

enum _HeatMode {
  density('Density'),
  severity('Severity'),
  unresolved('Unresolved'),
  nearSchools('Near schools');

  const _HeatMode(this.label);
  final String label;
}

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({
    super.key,
    required this.client,
    required this.isActive,
    this.enableMapTiles = true,
  });

  final SupabaseClient? client;
  final bool isActive;
  final bool enableMapTiles;

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  final _schoolSearchController = TextEditingController();
  final _exportService = const AnalyticsExportService();
  AnalyticsRepository? _repository;
  StreamSubscription<AuthState>? _authSubscription;
  Timer? _realtimeDebounce;
  Timer? _mapDebounce;
  late AnalyticsFilter _filter;
  AnalyticsData? _data;
  List<AnalyticsSchoolOption> _schools = [];
  final Set<String> _comparisonSchools = {};
  bool _loading = false;
  bool _loadingMore = false;
  bool _exporting = false;
  int _loadVersion = 0;
  String? _error;
  _HeatMode _heatMode = _HeatMode.density;
  bool _showMarkers = true;
  AnalyticsBounds? _lastMapBounds;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _filter = AnalyticsFilter(
      from: now.subtract(const Duration(days: 30)),
      to: now,
    );
    if (widget.isActive) {
      _startLiveAnalytics();
    }
  }

  @override
  void didUpdateWidget(covariant AnalyticsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _startLiveAnalytics();
    }
  }

  void _startLiveAnalytics() {
    final client = widget.client;
    if (client == null || _repository != null) return;
    _repository = AnalyticsRepository(client);
    _repository!.subscribeToChanges(_onRealtimeChange);
    _authSubscription = client.auth.onAuthStateChange.listen((_) {
      unawaited(_load(refreshSchools: true));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load(refreshSchools: true));
    });
  }

  @override
  void dispose() {
    _schoolSearchController.dispose();
    _realtimeDebounce?.cancel();
    _mapDebounce?.cancel();
    _authSubscription?.cancel();
    // The Supabase client owns channel teardown. Explicitly removing a channel
    // here starts a delayed socket-disconnect timer in realtime_client, which
    // can outlive Flutter's widget lifecycle and test binding.
    super.dispose();
  }

  void _onRealtimeChange() {
    _realtimeDebounce?.cancel();
    _realtimeDebounce = Timer(const Duration(milliseconds: 450), () {
      if (mounted) unawaited(_load());
    });
  }

  Future<void> _load({bool refreshSchools = false}) async {
    final repository = _repository;
    if (repository == null) return;
    final version = ++_loadVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        repository.fetch(_filter, limit: 500),
        if (refreshSchools || _schools.isEmpty) repository.fetchSchools(),
      ]);
      if (!mounted || version != _loadVersion) return;
      final data = results.first as AnalyticsData;
      final schools = results.length > 1
          ? results[1] as List<AnalyticsSchoolOption>
          : _schools;
      setState(() {
        _data = data;
        _schools = schools;
        _comparisonSchools.removeWhere(
          (id) => !data.schools.any((school) => school.id == id),
        );
        for (final school in data.schools) {
          if (_comparisonSchools.length >= 3) break;
          _comparisonSchools.add(school.id);
        }
      });
    } catch (error) {
      if (mounted && version == _loadVersion) {
        setState(() => _error = _friendlyError(error));
      }
    } finally {
      if (mounted && version == _loadVersion) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadMore() async {
    final repository = _repository;
    final current = _data;
    if (repository == null || current == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final next = await repository.fetch(
        _filter,
        limit: 500,
        offset: current.markers.length,
      );
      if (!mounted) return;
      setState(() {
        _data = current.withMarkers([
          ...current.markers,
          ...next.markers,
        ], next.pagination);
      });
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<AnalyticsData> _loadAllMarkers() async {
    final repository = _repository;
    final startingData = _data;
    if (repository == null || startingData == null) {
      throw StateError('Analytics are not available.');
    }
    AnalyticsData current = startingData;
    final markers = [...current.markers];
    var hasMore = current.pagination.hasMore;
    while (hasMore) {
      final next = await repository.fetch(
        _filter,
        limit: 1000,
        offset: markers.length,
      );
      markers.addAll(next.markers);
      current = current.withMarkers(markers, next.pagination);
      hasMore = next.pagination.hasMore;
    }
    if (mounted) setState(() => _data = current);
    return current;
  }

  void _updateFilter(AnalyticsFilter filter) {
    setState(() => _filter = filter);
    unawaited(_load());
  }

  Future<void> _chooseCustomRange() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: DateTimeRange(start: _filter.from, end: _filter.to),
      helpText: 'Choose analytics date range',
    );
    if (range == null) return;
    _updateFilter(
      _filter.copyWith(
        from: DateTime(range.start.year, range.start.month, range.start.day),
        to: DateTime(
          range.end.year,
          range.end.month,
          range.end.day,
        ).add(const Duration(days: 1)),
      ),
    );
  }

  Future<void> _chooseSchools() async {
    final selected = {..._filter.schoolIds};
    var query = '';
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final visible = _schools.where((school) {
            final value = '${school.name} ${school.district}'.toLowerCase();
            return value.contains(query.toLowerCase());
          }).toList();
          return AlertDialog(
            title: const Text('Filter by school'),
            content: SizedBox(
              width: 520,
              height: 460,
              child: Column(
                children: [
                  TextField(
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Search schools',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (value) =>
                        setDialogState(() => query = value.trim()),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: visible.isEmpty
                        ? const Center(child: Text('No schools match.'))
                        : ListView.builder(
                            itemCount: visible.length,
                            itemBuilder: (context, index) {
                              final school = visible[index];
                              return CheckboxListTile(
                                value: selected.contains(school.id),
                                title: Text(school.name),
                                subtitle: Text(school.district),
                                onChanged: (checked) => setDialogState(() {
                                  checked == true
                                      ? selected.add(school.id)
                                      : selected.remove(school.id);
                                }),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, <String>{}),
                child: const Text('Clear'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, selected),
                child: const Text('Apply'),
              ),
            ],
          );
        },
      ),
    );
    if (result != null) _updateFilter(_filter.copyWith(schoolIds: result));
  }

  Future<void> _showExportDialog() async {
    final current = _data;
    if (current == null) return;
    var format = AnalyticsExportFormat.pdf;
    final datasets = AnalyticsDataset.values.toSet();
    final request =
        await showDialog<
          ({AnalyticsExportFormat format, Set<AnalyticsDataset> datasets})
        >(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: const Text('Export analytics'),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${DateFormat.yMMMd().format(_filter.from)} – ${DateFormat.yMMMd().format(_filter.to)}',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Uses the active school, district, area, category, severity, and status filters.',
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<AnalyticsExportFormat>(
                        initialValue: format,
                        decoration: const InputDecoration(
                          labelText: 'File format',
                        ),
                        items: [
                          for (final value in AnalyticsExportFormat.values)
                            DropdownMenuItem(
                              value: value,
                              child: Text(value.label),
                            ),
                        ],
                        onChanged: (value) => setDialogState(() {
                          if (value != null) format = value;
                          if (format == AnalyticsExportFormat.geoJson) {
                            datasets
                              ..clear()
                              ..add(AnalyticsDataset.hazards);
                          }
                        }),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'Datasets',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      for (final dataset in AnalyticsDataset.values)
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          value: datasets.contains(dataset),
                          title: Text(dataset.label),
                          onChanged: format == AnalyticsExportFormat.geoJson
                              ? null
                              : (checked) => setDialogState(() {
                                  checked == true
                                      ? datasets.add(dataset)
                                      : datasets.remove(dataset);
                                }),
                        ),
                      const SizedBox(height: 8),
                      const Text(
                        'Privacy: exports never include reporter identifiers or free-form report descriptions.',
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  onPressed: datasets.isEmpty
                      ? null
                      : () => Navigator.pop(context, (
                          format: format,
                          datasets: {...datasets},
                        )),
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('Export'),
                ),
              ],
            ),
          ),
        );
    if (request == null) return;
    setState(() => _exporting = true);
    try {
      final complete = request.datasets.contains(AnalyticsDataset.hazards)
          ? await _loadAllMarkers()
          : current;
      await _exportService.export(
        data: complete,
        format: request.format,
        datasets: request.datasets,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${request.format.label} export created.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: ${_friendlyError(error)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.client == null) return const _AnalyticsNotConfigured();
    final data = _data;
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: () => _load(refreshSchools: true),
          child: CustomScrollView(
            key: const ValueKey('analytics-scroll-view'),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 36),
                sliver: SliverList.list(
                  children: [
                    PageIntro(
                      eyebrow: 'Community intelligence',
                      title: 'Hazard analytics',
                      description: 'Track patterns, compare schools, and measure resolution progress using live, permission-aware community reports.',
                      icon: Icons.analytics_outlined,
                      trailing: FilledButton.icon(
                        onPressed: data == null || _exporting
                            ? null
                            : _showExportDialog,
                        icon: _exporting
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.download_outlined),
                        label: const Text('Export'),
                      ),
                    ),
                    const SizedBox(height: 20),
                    _FilterPanel(
                      filter: _filter,
                      schools: _schools,
                      onCustomRange: _chooseCustomRange,
                      onChooseSchools: _chooseSchools,
                      onChanged: _updateFilter,
                      mapBounds: _lastMapBounds,
                    ),
                    if (_error case final error?) ...[
                      const SizedBox(height: 16),
                      _ErrorCard(message: error, onRetry: _load),
                    ],
                    if (data == null && _loading) ...[
                      const SizedBox(height: 72),
                      const Center(child: CircularProgressIndicator()),
                    ] else if (data != null) ...[
                      const SizedBox(height: 20),
                      _OverviewGrid(data: data),
                      const SizedBox(height: 20),
                      _AnalyticsMap(
                        data: data,
                        enableMapTiles: widget.enableMapTiles,
                        heatMode: _heatMode,
                        showMarkers: _showMarkers,
                        onHeatModeChanged: (value) =>
                            setState(() => _heatMode = value),
                        onShowMarkersChanged: (value) =>
                            setState(() => _showMarkers = value),
                        onBoundsChanged: _onMapBoundsChanged,
                      ),
                      if (data.pagination.hasMore) ...[
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.center,
                          child: OutlinedButton.icon(
                            onPressed: _loadingMore ? null : _loadMore,
                            icon: _loadingMore
                                ? const SizedBox.square(
                                    dimension: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.expand_more),
                            label: Text(
                              'Load more map points (${data.markers.length} of ${data.pagination.total})',
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                      _ChartsGrid(data: data),
                      const SizedBox(height: 20),
                      _SchoolAnalyticsSection(
                        data: data,
                        searchController: _schoolSearchController,
                        selectedIds: _comparisonSchools,
                        onSelectionChanged: () => setState(() {}),
                      ),
                      const SizedBox(height: 20),
                      _CategorySection(
                        data: data,
                        selected: _filter.types,
                        onToggle: (type) {
                          final values = {..._filter.types};
                          values.contains(type)
                              ? values.remove(type)
                              : values.add(type);
                          _updateFilter(_filter.copyWith(types: values));
                        },
                      ),
                      const SizedBox(height: 20),
                      _MethodologyNotice(data: data),
                    ] else ...[
                      const SizedBox(height: 48),
                      const _EmptyAnalytics(),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_loading && data != null)
          const Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }

  void _onMapBoundsChanged(AnalyticsBounds bounds) {
    final firstBounds = _lastMapBounds == null;
    _lastMapBounds = bounds;
    if (firstBounds) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
    if (_filter.bounds == null) return;
    _mapDebounce?.cancel();
    _mapDebounce = Timer(const Duration(milliseconds: 500), () {
      if (mounted) _updateFilter(_filter.copyWith(bounds: bounds));
    });
  }
}

class _FilterPanel extends StatelessWidget {
  const _FilterPanel({
    required this.filter,
    required this.schools,
    required this.onCustomRange,
    required this.onChooseSchools,
    required this.onChanged,
    required this.mapBounds,
  });

  final AnalyticsFilter filter;
  final List<AnalyticsSchoolOption> schools;
  final VoidCallback onCustomRange;
  final VoidCallback onChooseSchools;
  final ValueChanged<AnalyticsFilter> onChanged;
  final AnalyticsBounds? mapBounds;

  @override
  Widget build(BuildContext context) {
    final districts = schools.map((school) => school.district).toSet().toList()
      ..sort();
    final selectedDays = filter.to.difference(filter.from).inDays;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.tune, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 10),
              Text(
                'Global filters',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () {
                  final now = DateTime.now();
                  onChanged(
                    AnalyticsFilter(
                      from: now.subtract(const Duration(days: 30)),
                      to: now,
                    ),
                  );
                },
                icon: const Icon(Icons.restart_alt),
                label: const Text('Reset'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final days in const [7, 30, 90])
                ChoiceChip(
                  label: Text('$days days'),
                  selected: selectedDays == days,
                  onSelected: (_) {
                    final now = DateTime.now();
                    onChanged(
                      filter.copyWith(
                        from: now.subtract(Duration(days: days)),
                        to: now,
                      ),
                    );
                  },
                ),
              ActionChip(
                avatar: const Icon(Icons.date_range, size: 18),
                label: Text(
                  '${DateFormat.MMMd().format(filter.from)} – ${DateFormat.MMMd().format(filter.to)}',
                ),
                onPressed: onCustomRange,
              ),
              DropdownButton<AnalyticsBucket>(
                value: filter.bucket,
                borderRadius: BorderRadius.circular(12),
                items: [
                  for (final value in AnalyticsBucket.values)
                    DropdownMenuItem(value: value, child: Text(value.label)),
                ],
                onChanged: (value) {
                  if (value != null) onChanged(filter.copyWith(bucket: value));
                },
              ),
              ActionChip(
                avatar: const Icon(Icons.school_outlined, size: 18),
                label: Text(
                  filter.schoolIds.isEmpty
                      ? 'All schools'
                      : '${filter.schoolIds.length} schools',
                ),
                onPressed: onChooseSchools,
              ),
              PopupMenuButton<String>(
                tooltip: 'Filter districts',
                itemBuilder: (context) => [
                  for (final district in districts)
                    CheckedPopupMenuItem(
                      value: district,
                      checked: filter.districts.contains(district),
                      child: Text(district),
                    ),
                ],
                onSelected: (district) {
                  final values = {...filter.districts};
                  values.contains(district)
                      ? values.remove(district)
                      : values.add(district);
                  onChanged(filter.copyWith(districts: values));
                },
                child: _FilterButton(
                  label: filter.districts.isEmpty
                      ? 'All districts'
                      : '${filter.districts.length} districts',
                  icon: Icons.apartment_outlined,
                ),
              ),
              PopupMenuButton<int>(
                tooltip: 'Filter severity',
                itemBuilder: (context) => [
                  for (var severity = 1; severity <= 5; severity++)
                    CheckedPopupMenuItem(
                      value: severity,
                      checked: filter.severities.contains(severity),
                      child: Text('Severity $severity'),
                    ),
                ],
                onSelected: (severity) {
                  final values = {...filter.severities};
                  values.contains(severity)
                      ? values.remove(severity)
                      : values.add(severity);
                  onChanged(filter.copyWith(severities: values));
                },
                child: _FilterButton(
                  label: filter.severities.isEmpty
                      ? 'All severities'
                      : '${filter.severities.length} severities',
                  icon: Icons.priority_high,
                ),
              ),
              FilterChip(
                avatar: const Icon(Icons.crop_free, size: 18),
                label: Text(
                  filter.bounds == null ? 'All areas' : 'Visible map area',
                ),
                selected: filter.bounds != null,
                onSelected: mapBounds != null || filter.bounds != null
                    ? (selected) => onChanged(
                        selected
                            ? filter.copyWith(bounds: mapBounds)
                            : filter.copyWith(clearBounds: true),
                      )
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final type in HazardType.values)
                FilterChip(
                  label: Text(type.label),
                  selected: filter.types.contains(type),
                  onSelected: (_) {
                    final values = {...filter.types};
                    values.contains(type)
                        ? values.remove(type)
                        : values.add(type);
                    onChanged(filter.copyWith(types: values));
                  },
                ),
              for (final status in ReportStatus.values)
                FilterChip(
                  avatar: Icon(_statusIcon(status), size: 16),
                  label: Text(status.label),
                  selected: filter.statuses.contains(status),
                  onSelected: (_) {
                    final values = {...filter.statuses};
                    values.contains(status)
                        ? values.remove(status)
                        : values.add(status);
                    onChanged(filter.copyWith(statuses: values));
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.label, required this.icon});
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 7),
        Text(label),
        const Icon(Icons.arrow_drop_down),
      ],
    ),
  );
}

class _OverviewGrid extends StatelessWidget {
  const _OverviewGrid({required this.data});
  final AnalyticsData data;

  @override
  Widget build(BuildContext context) {
    final current = data.summary;
    final previous = data.previousSummary;
    final metrics = [
      (
        'Total hazards',
        current.total.toDouble(),
        previous.total.toDouble(),
        Icons.warning_amber_rounded,
        '',
      ),
      (
        'Pending',
        current.pending.toDouble(),
        previous.pending.toDouble(),
        Icons.schedule,
        '',
      ),
      (
        'Verified',
        current.verified.toDouble(),
        previous.verified.toDouble(),
        Icons.verified_outlined,
        '',
      ),
      (
        'Resolved',
        current.resolved.toDouble(),
        previous.resolved.toDouble(),
        Icons.task_alt,
        '',
      ),
      (
        'High priority',
        current.highPriority.toDouble(),
        previous.highPriority.toDouble(),
        Icons.priority_high,
        '',
      ),
      (
        'Resolution rate',
        current.resolutionRate,
        previous.resolutionRate,
        Icons.speed,
        '%',
      ),
      (
        'Avg. resolution',
        current.averageResolutionHours,
        previous.averageResolutionHours,
        Icons.timer_outlined,
        'h',
      ),
      (
        'Affected schools',
        current.affectedSchools.toDouble(),
        previous.affectedSchools.toDouble(),
        Icons.school_outlined,
        '',
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1100
            ? 4
            : constraints.maxWidth >= 620
            ? 2
            : 1;
        final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final metric in metrics)
              SizedBox(
                width: width,
                child: _MetricCard(
                  label: metric.$1,
                  value: metric.$2,
                  previous: metric.$3,
                  icon: metric.$4,
                  suffix: metric.$5,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.previous,
    required this.icon,
    required this.suffix,
  });
  final String label;
  final double? value;
  final double? previous;
  final IconData icon;
  final String suffix;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final delta = value == null || previous == null ? null : value! - previous!;
    final formatted = value == null
        ? 'N/A'
        : '${value! % 1 == 0 ? value!.toInt() : value!.toStringAsFixed(1)}$suffix';
    return SectionCard(
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: colors.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  formatted,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                Text(label, style: TextStyle(color: colors.onSurfaceVariant)),
                const SizedBox(height: 4),
                Text(
                  delta == null
                      ? 'No prior comparison'
                      : '${delta >= 0 ? '+' : ''}${delta % 1 == 0 ? delta.toInt() : delta.toStringAsFixed(1)}$suffix vs previous period',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: delta == null
                        ? colors.onSurfaceVariant
                        : delta > 0
                        ? colors.tertiary
                        : colors.primary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AnalyticsMap extends StatelessWidget {
  const _AnalyticsMap({
    required this.data,
    required this.enableMapTiles,
    required this.heatMode,
    required this.showMarkers,
    required this.onHeatModeChanged,
    required this.onShowMarkersChanged,
    required this.onBoundsChanged,
  });

  final AnalyticsData data;
  final bool enableMapTiles;
  final _HeatMode heatMode;
  final bool showMarkers;
  final ValueChanged<_HeatMode> onHeatModeChanged;
  final ValueChanged<bool> onShowMarkersChanged;
  final ValueChanged<AnalyticsBounds> onBoundsChanged;

  @override
  Widget build(BuildContext context) {
    final markers = data.markers
        .where(
          (marker) => switch (heatMode) {
            _HeatMode.unresolved =>
              marker.status != ReportStatus.resolved &&
                  marker.status != ReportStatus.rejected,
            _HeatMode.nearSchools => marker.distanceToSchoolMeters <= 800,
            _ => true,
          },
        )
        .toList();
    final center = markers.isNotEmpty
        ? markers.first.location
        : data.schools.isNotEmpty
        ? LatLng(data.schools.first.latitude, data.schools.first.longitude)
        : PilotSchool.location;
    return SectionCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Wrap(
              spacing: 14,
              runSpacing: 12,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Interactive hazard map',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      '${markers.length} deduplicated points in this view',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    DropdownButton<_HeatMode>(
                      value: heatMode,
                      items: [
                        for (final mode in _HeatMode.values)
                          DropdownMenuItem(
                            value: mode,
                            child: Text('${mode.label} heatmap'),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) onHeatModeChanged(value);
                      },
                    ),
                    FilterChip(
                      avatar: const Icon(Icons.location_on_outlined, size: 18),
                      label: const Text('Individual markers'),
                      selected: showMarkers,
                      onSelected: onShowMarkersChanged,
                    ),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(
            height: 440,
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(20),
              ),
              child: FlutterMap(
                options: MapOptions(
                  initialCenter: center,
                  initialZoom: 12,
                  minZoom: 3,
                  maxZoom: 19,
                  onPositionChanged: (camera, _) {
                    final bounds = camera.visibleBounds;
                    onBoundsChanged(
                      AnalyticsBounds(
                        minLatitude: bounds.south,
                        minLongitude: bounds.west,
                        maxLatitude: bounds.north,
                        maxLongitude: bounds.east,
                      ),
                    );
                  },
                ),
                children: [
                  if (enableMapTiles)
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'org.saferoutes.prototype',
                    ),
                  CircleLayer(
                    circles: [
                      for (final marker in markers)
                        CircleMarker(
                          point: marker.location,
                          radius: _heatRadius(marker, heatMode),
                          color: _heatColor(
                            marker,
                            heatMode,
                          ).withValues(alpha: .20),
                          borderColor: _heatColor(
                            marker,
                            heatMode,
                          ).withValues(alpha: .28),
                          borderStrokeWidth: 1,
                        ),
                    ],
                  ),
                  if (showMarkers)
                    MarkerLayer(
                      markers: [
                        for (final marker in markers)
                          Marker(
                            point: marker.location,
                            width: 40,
                            height: 40,
                            child: Tooltip(
                              message:
                                  '${marker.type.label}\nSeverity ${marker.severity} • ${marker.status.label}\n${marker.schoolName}',
                              child: Container(
                                decoration: BoxDecoration(
                                  color: _statusColor(marker.status),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 2,
                                  ),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Colors.black26,
                                      blurRadius: 6,
                                    ),
                                  ],
                                ),
                                child: const Icon(
                                  Icons.warning_amber_rounded,
                                  color: Colors.white,
                                  size: 21,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  Positioned(
                    left: 10,
                    right: 10,
                    bottom: 10,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: .92),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          '© OpenStreetMap contributors • Community reports are not a safety audit',
                          style: TextStyle(fontSize: 10),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChartsGrid extends StatelessWidget {
  const _ChartsGrid({required this.data});
  final AnalyticsData data;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 980;
      final width = wide
          ? (constraints.maxWidth - 16) / 2
          : constraints.maxWidth;
      return Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          SizedBox(
            width: width,
            child: _TrendChart(data: data),
          ),
          SizedBox(
            width: width,
            child: _CategoryChart(data: data),
          ),
          SizedBox(
            width: width,
            child: _DistributionChart(data: data),
          ),
          SizedBox(
            width: width,
            child: _SchoolStackedChart(data: data),
          ),
        ],
      );
    },
  );
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => SectionCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 3),
        Text(
          subtitle,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(height: 260, child: child),
      ],
    ),
  );
}

class _TrendChart extends StatelessWidget {
  const _TrendChart({required this.data});
  final AnalyticsData data;

  @override
  Widget build(BuildContext context) => _ChartCard(
    title: 'Reports over time',
    subtitle: '${data.bucket.label} unique hazards',
    child: data.trend.isEmpty
        ? const _ChartEmpty()
        : LineChart(
            LineChartData(
              minY: 0,
              gridData: const FlGridData(show: true, drawVerticalLine: false),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                rightTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                leftTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: true, reservedSize: 30),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 34,
                    interval: math.max(
                      1,
                      (data.trend.length / 4).ceilToDouble(),
                    ),
                    getTitlesWidget: (value, meta) {
                      final index = value.toInt();
                      if (index < 0 || index >= data.trend.length) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          DateFormat('M/d')
                              .format(data.trend[index].period.toLocal()),
                          style: const TextStyle(fontSize: 10),
                        ),
                      );
                    },
                  ),
                ),
              ),
              lineTouchData: const LineTouchData(enabled: true),
              lineBarsData: [
                LineChartBarData(
                  spots: [
                    for (var i = 0; i < data.trend.length; i++)
                      FlSpot(i.toDouble(), data.trend[i].total.toDouble()),
                  ],
                  color: Theme.of(context).colorScheme.primary,
                  barWidth: 3,
                  isCurved: true,
                  belowBarData: BarAreaData(
                    show: true,
                    color: Theme.of(context).colorScheme.primary
                        .withValues(alpha: .12),
                  ),
                ),
              ],
            ),
          ),
  );
}

class _CategoryChart extends StatelessWidget {
  const _CategoryChart({required this.data});
  final AnalyticsData data;

  @override
  Widget build(BuildContext context) => _ChartCard(
    title: 'Hazard categories',
    subtitle: 'Counts by infrastructure concern',
    child: data.categories.isEmpty
        ? const _ChartEmpty()
        : BarChart(
            BarChartData(
              alignment: BarChartAlignment.spaceAround,
              maxY:
                  data.categories
                      .fold<int>(
                        1,
                        (value, item) => math.max(value, item.count),
                      )
                      .toDouble() +
                  1,
              borderData: FlBorderData(show: false),
              gridData: const FlGridData(show: true, drawVerticalLine: false),
              barTouchData: BarTouchData(enabled: true),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                rightTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                leftTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: true, reservedSize: 28),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 42,
                    getTitlesWidget: (value, meta) {
                      final index = value.toInt();
                      if (index < 0 || index >= data.categories.length) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 7),
                        child: Text(
                          _shortCategory(data.categories[index].key),
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 9),
                        ),
                      );
                    },
                  ),
                ),
              ),
              barGroups: [
                for (var i = 0; i < data.categories.length; i++)
                  BarChartGroupData(
                    x: i,
                    barRods: [
                      BarChartRodData(
                        toY: data.categories[i].count.toDouble(),
                        width: 22,
                        color: Theme.of(context).colorScheme.secondary,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(6),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
  );
}

class _DistributionChart extends StatelessWidget {
  const _DistributionChart({required this.data});
  final AnalyticsData data;

  @override
  Widget build(BuildContext context) {
    final visible = data.statuses.where((item) => item.count > 0).toList();
    return _ChartCard(
      title: 'Report status',
      subtitle: 'Distribution across the current filters',
      child: visible.isEmpty
          ? const _ChartEmpty()
          : Row(
              children: [
                Expanded(
                  child: PieChart(
                    PieChartData(
                      centerSpaceRadius: 48,
                      sectionsSpace: 3,
                      pieTouchData: PieTouchData(enabled: true),
                      sections: [
                        for (final item in visible)
                          PieChartSectionData(
                            value: item.count.toDouble(),
                            color: _statusColor(_statusFromKey(item.key)),
                            radius: 54,
                            title: '${item.percentage.toStringAsFixed(0)}%',
                            titleStyle: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final item in visible)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: _statusColor(_statusFromKey(item.key)),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 7),
                            Text(
                              '${_statusFromKey(item.key).label} (${item.count})',
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
    );
  }
}

class _SchoolStackedChart extends StatelessWidget {
  const _SchoolStackedChart({required this.data});
  final AnalyticsData data;

  @override
  Widget build(BuildContext context) {
    final schools = data.schools.take(6).toList();
    return _ChartCard(
      title: 'Schools compared',
      subtitle: 'Pending, verified, and resolved hazards',
      child: schools.isEmpty
          ? const _ChartEmpty()
          : BarChart(
              BarChartData(
                borderData: FlBorderData(show: false),
                gridData: const FlGridData(show: true, drawVerticalLine: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  leftTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: true, reservedSize: 28),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 44,
                      getTitlesWidget: (value, meta) {
                        final index = value.toInt();
                        if (index < 0 || index >= schools.length) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 7),
                          child: SizedBox(
                            width: 64,
                            child: Text(
                              _schoolShortName(schools[index].name),
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 9),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                barGroups: [
                  for (var i = 0; i < schools.length; i++)
                    BarChartGroupData(
                      x: i,
                      barRods: [
                        BarChartRodData(
                          toY:
                              (schools[i].pending +
                                      schools[i].verified +
                                      schools[i].resolved)
                                  .toDouble(),
                          width: 24,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(5),
                          ),
                          rodStackItems: [
                            BarChartRodStackItem(
                              0,
                              schools[i].pending.toDouble(),
                              _statusColor(ReportStatus.unverified),
                            ),
                            BarChartRodStackItem(
                              schools[i].pending.toDouble(),
                              (schools[i].pending + schools[i].verified)
                                  .toDouble(),
                              _statusColor(ReportStatus.verified),
                            ),
                            BarChartRodStackItem(
                              (schools[i].pending + schools[i].verified)
                                  .toDouble(),
                              (schools[i].pending +
                                      schools[i].verified +
                                      schools[i].resolved)
                                  .toDouble(),
                              _statusColor(ReportStatus.resolved),
                            ),
                          ],
                        ),
                      ],
                    ),
                ],
              ),
            ),
    );
  }
}

class _SchoolAnalyticsSection extends StatefulWidget {
  const _SchoolAnalyticsSection({
    required this.data,
    required this.searchController,
    required this.selectedIds,
    required this.onSelectionChanged,
  });
  final AnalyticsData data;
  final TextEditingController searchController;
  final Set<String> selectedIds;
  final VoidCallback onSelectionChanged;

  @override
  State<_SchoolAnalyticsSection> createState() =>
      _SchoolAnalyticsSectionState();
}

class _SchoolAnalyticsSectionState extends State<_SchoolAnalyticsSection> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final matching = widget.data.schools
        .where(
          (school) => '${school.name} ${school.district}'
              .toLowerCase()
              .contains(_query.toLowerCase()),
        )
        .toList();
    final selected = widget.data.schools
        .where((school) => widget.selectedIds.contains(school.id))
        .toList();
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'School analytics',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Text(
            'Search and select up to four schools for a side-by-side comparison.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: widget.searchController,
            decoration: const InputDecoration(
              labelText: 'Search schools',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (value) => setState(() => _query = value.trim()),
          ),
          if (_query.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final school in matching.take(8))
                  FilterChip(
                    label: Text(school.name),
                    selected: widget.selectedIds.contains(school.id),
                    onSelected: (enabled) {
                      if (enabled && widget.selectedIds.length >= 4) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Compare up to four schools at a time.',
                            ),
                          ),
                        );
                        return;
                      }
                      enabled
                          ? widget.selectedIds.add(school.id)
                          : widget.selectedIds.remove(school.id);
                      widget.onSelectionChanged();
                    },
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          if (selected.isEmpty)
            const _ChartEmpty(
              message: 'No schools have hazards in the selected filters.',
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth >= 900
                    ? (constraints.maxWidth - 12) / 2
                    : constraints.maxWidth;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final school in selected)
                      SizedBox(
                        width: width,
                        child: _SchoolCard(school: school),
                      ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}

class _SchoolCard extends StatelessWidget {
  const _SchoolCard({required this.school});
  final SchoolAnalytics school;

  @override
  Widget build(BuildContext context) {
    final topCategory = school.categories.firstOrNull;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(child: const Icon(Icons.school_outlined)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      school.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      school.district,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              StatusPill(label: '${school.total} nearby hazards'),
              StatusPill(
                label: '${school.highPriority} high priority',
                backgroundColor: const Color(0xFFFFE5E5),
                foregroundColor: const Color(0xFF8A1C1C),
              ),
              StatusPill(
                label: '${school.resolutionRate.toStringAsFixed(1)}% resolved',
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Most common: ${topCategory == null ? 'No category data' : '${_categoryLabel(topCategory.key)} (${topCategory.count})'}',
          ),
          Text(
            'Average severity: ${school.averageSeverity.toStringAsFixed(1)} / 5',
          ),
          Text(
            'Average resolution time: ${school.averageResolutionHours == null ? 'Not available' : _durationLabel(school.averageResolutionHours!)}',
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: school.resolutionRate / 100,
            minHeight: 8,
            borderRadius: BorderRadius.circular(99),
          ),
        ],
      ),
    );
  }
}

class _CategorySection extends StatelessWidget {
  const _CategorySection({
    required this.data,
    required this.selected,
    required this.onToggle,
  });
  final AnalyticsData data;
  final Set<HazardType> selected;
  final ValueChanged<HazardType> onToggle;

  @override
  Widget build(BuildContext context) => SectionCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Hazard category detail',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        Text(
          'Select a row to focus every statistic, chart, map, and export on that category.',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 14),
        if (data.categories.isEmpty)
          const _ChartEmpty()
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('Category')),
                DataColumn(label: Text('Count'), numeric: true),
                DataColumn(label: Text('Share'), numeric: true),
                DataColumn(label: Text('Previous'), numeric: true),
                DataColumn(label: Text('Trend')),
              ],
              rows: [
                for (final item in data.categories)
                  DataRow(
                    selected: selected.contains(_typeFromKey(item.key)),
                    onSelectChanged: (_) => onToggle(_typeFromKey(item.key)),
                    cells: [
                      DataCell(Text(_categoryLabel(item.key))),
                      DataCell(Text('${item.count}')),
                      DataCell(Text('${item.percentage.toStringAsFixed(1)}%')),
                      DataCell(Text('${item.previousCount ?? 0}')),
                      DataCell(
                        Icon(
                          item.count >= (item.previousCount ?? 0)
                              ? Icons.trending_up
                              : Icons.trending_down,
                          color: item.count > (item.previousCount ?? 0)
                              ? Colors.deepOrange
                              : Colors.teal,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}

class _MethodologyNotice extends StatelessWidget {
  const _MethodologyNotice({required this.data});
  final AnalyticsData data;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF7E8),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFFF1D9A7)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, color: Color(0xFF795300)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'How to read these analytics',
                style: TextStyle(
                  color: Color(0xFF604300),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${data.deduplication.duplicatesRemoved} repeat reports were consolidated (${data.deduplication.method}). Counts reflect only reports the current user may read under Row Level Security. Community severity is self-reported; an unverified report is not a verified hazard, and the map is not a safety audit.',
                style: const TextStyle(color: Color(0xFF795E25), height: 1.4),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _AnalyticsNotConfigured extends StatelessWidget {
  const _AnalyticsNotConfigured();

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: const [
      PageIntro(
        eyebrow: 'Community intelligence',
        title: 'Hazard analytics',
        description: 'Connect Supabase to load privacy-safe, permission-aware hazard statistics.',
        icon: Icons.analytics_outlined,
      ),
      SizedBox(height: 24),
      SectionCard(
        child: _ChartEmpty(
          message: 'Supabase is not configured. Analytics never substitutes placeholder data.',
        ),
      ),
    ],
  );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onRetry});
  final String message;
  final Future<void> Function({bool refreshSchools}) onRetry;

  @override
  Widget build(BuildContext context) => SectionCard(
    color: Theme.of(context).colorScheme.errorContainer,
    child: Row(
      children: [
        Icon(
          Icons.error_outline,
          color: Theme.of(context).colorScheme.onErrorContainer,
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(message)),
        TextButton(onPressed: () => onRetry(), child: const Text('Retry')),
      ],
    ),
  );
}

class _EmptyAnalytics extends StatelessWidget {
  const _EmptyAnalytics();
  @override
  Widget build(BuildContext context) => const SectionCard(
    child: _ChartEmpty(
      message: 'No analytics data is available for these filters.',
    ),
  );
}

class _ChartEmpty extends StatelessWidget {
  const _ChartEmpty({this.message = 'No reports match the selected filters.'});
  final String message;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.query_stats,
          size: 36,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}

double _heatRadius(AnalyticsMarker marker, _HeatMode mode) => switch (mode) {
  _HeatMode.density => 24 + math.min(marker.duplicateCount, 6) * 4,
  _HeatMode.severity => 18 + marker.severity * 7,
  _HeatMode.unresolved => 28 + marker.severity * 4,
  _HeatMode.nearSchools =>
    48 - math.min(marker.distanceToSchoolMeters / 30, 24),
};

Color _heatColor(AnalyticsMarker marker, _HeatMode mode) => switch (mode) {
  _HeatMode.severity => Color.lerp(
    Colors.amber,
    Colors.red,
    (marker.severity - 1) / 4,
  )!,
  _HeatMode.unresolved =>
    marker.status == ReportStatus.verified ? Colors.red : Colors.orange,
  _HeatMode.nearSchools =>
    marker.distanceToSchoolMeters <= 300 ? Colors.deepPurple : Colors.indigo,
  _HeatMode.density => Colors.redAccent,
};

Color _statusColor(ReportStatus status) => switch (status) {
  ReportStatus.unverified => const Color(0xFFE09F1F),
  ReportStatus.verified => const Color(0xFF2D7DD2),
  ReportStatus.resolved => const Color(0xFF168A63),
  ReportStatus.rejected => const Color(0xFF7A7F87),
};

IconData _statusIcon(ReportStatus status) => switch (status) {
  ReportStatus.unverified => Icons.schedule,
  ReportStatus.verified => Icons.verified_outlined,
  ReportStatus.resolved => Icons.task_alt,
  ReportStatus.rejected => Icons.block,
};

ReportStatus _statusFromKey(String key) => ReportStatus.values.firstWhere(
  (status) => status.name == key,
  orElse: () => ReportStatus.unverified,
);

HazardType _typeFromKey(String key) => switch (key) {
  'missing_sidewalk' => HazardType.missingSidewalk,
  'difficult_crossing' => HazardType.difficultCrossing,
  'poor_lighting' => HazardType.poorLighting,
  'blocked_path' => HazardType.blockedPath,
  'bike_route' => HazardType.bikeRoute,
  _ => HazardType.missingSidewalk,
};

String _categoryLabel(String key) => _typeFromKey(key).label;
String _shortCategory(String key) => switch (key) {
  'missing_sidewalk' => 'Sidewalk',
  'difficult_crossing' => 'Crossing',
  'poor_lighting' => 'Lighting',
  'blocked_path' => 'Blocked',
  'bike_route' => 'Bike',
  _ => key,
};

String _schoolShortName(String value) {
  final words = value.split(' ');
  return words.length <= 2 ? value : '${words.first} ${words[1]}';
}

String _durationLabel(double hours) {
  if (hours < 24) return '${hours.toStringAsFixed(1)} hours';
  return '${(hours / 24).toStringAsFixed(1)} days';
}

String _friendlyError(Object error) {
  final message = error.toString().replaceFirst('Exception: ', '');
  if (message.contains('get_hazard_analytics')) {
    return 'The analytics database migration is not installed yet.';
  }
  return message;
}

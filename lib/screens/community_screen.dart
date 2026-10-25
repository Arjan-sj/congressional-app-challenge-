import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/hazard_report.dart';
import '../services/community_repository.dart';
import '../widgets/app_ui.dart';

class CommunityScreen extends StatefulWidget {
  const CommunityScreen({
    super.key,
    required this.reports,
    required this.onReview,
    this.client,
    this.refreshVersion = 0,
  });
  final List<HazardReport> reports;
  final ValueChanged<HazardReport> onReview;
  final SupabaseClient? client;
  final int refreshVersion;
  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> {
  String _filter = 'Awaiting review', _search = '';
  int _page = 0, _version = 0;
  Map<String, Map<String, dynamic>> _totals = {};
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant CommunityScreen old) {
    super.didUpdateWidget(old);
    if (old.refreshVersion != widget.refreshVersion ||
        old.reports != widget.reports) {
      _load();
    }
  }

  Future<void> _load() async {
    if (widget.client == null) return;
    final v = ++_version;
    try {
      final totals = await CommunityRepository(widget.client!)
          .totals(widget.reports.map((r) => r.id));
      if (mounted && v == _version) {
        setState(() {
          _totals = totals;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted && v == _version) {
        setState(
          () => _error = 'Review totals are unavailable. Refresh to retry.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final reports = widget.reports
        .where(
          (r) =>
              (r.schoolName ?? r.schoolId).toLowerCase().contains(
                _search.toLowerCase(),
              ) &&
              switch (_filter) {
                'Awaiting review' => r.status == ReportStatus.unverified,
                'Flagged' => (_totals[r.id]?['flags'] as num? ?? 0) > 0,
                'All' => true,
                _ => r.status.label == _filter,
              },
        )
        .toList();
    final pages = (reports.length / 25).ceil().clamp(1, 1 << 30),
        page = _page.clamp(0, pages - 1);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const PageIntro(
                  eyebrow: 'Community',
                  title: 'Review local concerns together',
                  description: 'Anyone can contribute an observation, vote or flag. Three agreeing reviews from independent connections are required to change a report’s status.',
                  icon: Icons.people_outline,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Share observations anonymously. A random browser token and private network hashes limit repeat reviews; they do not identify a person. Clearing browser storage loses your contribution history. New reports and photos are public.',
                ),
                const SizedBox(height: 16),
                TextField(
                  decoration: const InputDecoration(
                    labelText: 'Filter reports by school',
                  ),
                  onChanged: (v) => setState(() {
                    _search = v;
                    _page = 0;
                  }),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final filter in [
                      'Awaiting review',
                      'Flagged',
                      'Reviewed',
                      'Resolved',
                      'All',
                    ])
                      ChoiceChip(
                        label: Text(filter),
                        selected: _filter == filter,
                        onSelected: (_) => setState(() {
                          _filter = filter;
                          _page = 0;
                        }),
                      ),
                  ],
                ),
                if (_error != null)
                  TextButton(onPressed: _load, child: Text(_error!)),
                if (reports.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('No public reports in this view.'),
                  ),
                for (final report in reports.skip(page * 25).take(25))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: SectionCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            report.schoolName ?? report.schoolId,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text('${report.type.label} · ${report.status.label}'),
                          Text(report.description),
                          Text(
                            'Concern exists: ${_totals[report.id]?['verified'] ?? 0} · Resolved: ${_totals[report.id]?['resolved'] ?? 0} · Not accurate: ${_totals[report.id]?['rejected'] ?? 0} · Flags: ${_totals[report.id]?['flags'] ?? 0}',
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton(
                              onPressed: widget.client == null
                                  ? null
                                  : () => widget.onReview(report),
                              child: const Text('Review report'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(
                      onPressed: page == 0
                          ? null
                          : () => setState(() => _page = page - 1),
                      child: const Text('Previous'),
                    ),
                    Text('${page + 1} / $pages'),
                    TextButton(
                      onPressed: page + 1 >= pages
                          ? null
                          : () => setState(() => _page = page + 1),
                      child: const Text('Next'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

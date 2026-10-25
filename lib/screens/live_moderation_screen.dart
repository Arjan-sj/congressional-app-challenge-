import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/hazard_report.dart';
import '../models/moderation_queue.dart';
import '../services/moderation_repository.dart';
import '../widgets/app_ui.dart';
import 'moderation_scope_picker.dart';

class LiveModerationScreen extends StatefulWidget {
  const LiveModerationScreen({
    super.key,
    required this.client,
    required this.onReview,
    required this.onAccessLost,
    this.isActive = true,
    this.refreshVersion = 0,
  });
  final SupabaseClient client;
  final ValueChanged<HazardReport> onReview;
  final VoidCallback onAccessLost;
  final bool isActive;
  final int refreshVersion;
  @override
  State<LiveModerationScreen> createState() => _LiveModerationScreenState();
}

class _LiveModerationScreenState extends State<LiveModerationScreen> {
  ModerationQueue _queue = ModerationQueue.pending;
  ModerationOrder _order = ModerationOrder.priority;
  ModerationScope? _school, _district;
  ModerationQueuePage? _page;
  bool _loading = false;
  String? _error;
  int _offset = 0, _version = 0;
  ModerationRepository get _repository => ModerationRepository(widget.client);
  @override
  void initState() {
    super.initState();
    if (widget.isActive) unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant LiveModerationScreen old) {
    super.didUpdateWidget(old);
    if (widget.isActive &&
        (!old.isActive || widget.refreshVersion != old.refreshVersion)) {
      unawaited(_load(reset: true));
    }
  }

  @override
  void dispose() {
    _version++;
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    final version = ++_version;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _offset = 0;
        _page = null;
      }
    });
    try {
      var page = await _repository.fetch(
        queue: _queue,
        order: _order,
        schoolId: _school?.id,
        districtId: _district?.id,
        offset: _offset,
      );
      if (!mounted || version != _version) return;
      if (page.items.isEmpty && _offset > 0) {
        _offset = 0;
        page = await _repository.fetch(
          queue: _queue,
          order: _order,
          schoolId: _school?.id,
          districtId: _district?.id,
        );
      }
      if (!mounted || version != _version) return;
      setState(() => _page = page);
    } on PostgrestException catch (error) {
      if (!mounted || version != _version) return;
      setState(() {
        _page = null;
        _error = error.code == '42501'
            ? 'Moderator access is no longer available.'
            : 'Unable to load the review queue. Retry.';
      });
      if (error.code == '42501') widget.onAccessLost();
    } catch (_) {
      if (mounted && version == _version) {
        setState(() => _error = 'Unable to load the review queue. Retry.');
      }
    } finally {
      if (mounted && version == _version) setState(() => _loading = false);
    }
  }

  Future<void> _choose(String kind) async {
    final selected = await showDialog<({ModerationScope? scope})>(
      context: context,
      builder: (_) => ModerationScopePicker(
        repository: _repository,
        kind: kind,
        districtId: kind == 'school' ? _district?.id : null,
        onAccessLost: widget.onAccessLost,
      ),
    );
    if (!mounted || selected == null) return;
    setState(() {
      if (kind == 'school') {
        _school = selected.scope;
      } else {
        _district = selected.scope;
        _school = null;
      }
    });
    unawaited(_load(reset: true));
  }

  String _age(DateTime time) {
    final age = DateTime.now().difference(time);
    return age.inDays > 0
        ? '${age.inDays} days old'
        : age.inHours > 0
        ? '${age.inHours} hours old'
        : 'Less than an hour old';
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: ListView(
        key: const ValueKey('moderation-queue-scroll'),
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 40),
        children: [
          const PageIntro(
            eyebrow: 'Moderation',
            title: 'Review community reports',
            description: 'Review nationwide submissions and accuracy flags. Record a reason for every decision.',
            icon: Icons.fact_check_outlined,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final q in ModerationQueue.values)
                ChoiceChip(
                  label: Wrap(
                    spacing: 6,
                    children: [
                      Text(q.label),
                      if (page != null) Text('(${page.counts[q.name] ?? 0})'),
                    ],
                  ),
                  selected: _queue == q,
                  onSelected: (_) {
                    setState(() => _queue = q);
                    unawaited(_load(reset: true));
                  },
                ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: () => _choose('district'),
                icon: const Icon(Icons.account_balance_outlined),
                label: Text(_district?.name ?? 'All districts'),
              ),
              OutlinedButton.icon(
                onPressed: () => _choose('school'),
                icon: const Icon(Icons.school_outlined),
                label: Text(_school?.name ?? 'All schools'),
              ),
              SizedBox(
                width: 230,
                child: DropdownButtonFormField<ModerationOrder>(
                  initialValue: _order,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Order reports'),
                  items: [
                    for (final o in ModerationOrder.values)
                      DropdownMenuItem(value: o, child: Text(o.label)),
                  ],
                  onChanged: (o) {
                    if (o != null) {
                      setState(() => _order = o);
                      unawaited(_load(reset: true));
                    }
                  },
                ),
              ),
              TextButton.icon(
                onPressed: _loading ? null : () => _load(reset: true),
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh queue'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Counts are individual reports in the selected school/district, not deduplicated hazards. Priority orders severity, open flags, then oldest report.',
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            SectionCard(
              child: Wrap(
                children: [
                  Text(_error!),
                  TextButton(
                    onPressed: () => _load(),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          if (page != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text('${page.total} reports in this queue'),
            ),
            if (page.items.isEmpty)
              const SectionCard(child: Text('No reports in this queue.')),
            for (final item in page.items) ...[
              SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        Text(
                          item.report.type.label,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        StatusPill(label: item.report.status.label),
                        if (item.openFlags > 0)
                          StatusPill(
                            label: '${item.openFlags} open flags',
                            icon: Icons.flag_outlined,
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      item.report.schoolName ?? item.report.schoolId,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      '${item.districtName} · ${[item.schoolCity, item.schoolState].where((v) => v.isNotEmpty).join(', ')}',
                    ),
                    const SizedBox(height: 8),
                    Text(item.report.description),
                    const SizedBox(height: 8),
                    Text(
                      'Severity ${item.report.severity}/5 · ${_age(item.report.createdAt)} · ${DateFormat.yMMMd().add_jm().format(item.report.createdAt.toLocal())}',
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => widget.onReview(item.report),
                      icon: const Icon(Icons.fact_check_outlined),
                      label: const Text('Review report'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: _loading || _offset == 0
                      ? null
                      : () {
                          _offset = (_offset - page.limit).clamp(0, page.total);
                          unawaited(_load());
                        },
                  child: const Text('Previous'),
                ),
                Text('Page ${_offset ~/ page.limit + 1}'),
                OutlinedButton(
                  onPressed: _loading || !page.hasMore
                      ? null
                      : () {
                          _offset += page.limit;
                          unawaited(_load());
                        },
                  child: const Text('Next'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/hazard_report.dart';
import '../services/community_repository.dart';
import '../widgets/hazard_photo_view.dart';

class CommunityReviewDialog extends StatefulWidget {
  const CommunityReviewDialog({
    super.key,
    required this.client,
    required this.report,
    required this.onChanged,
  });
  final SupabaseClient client;
  final HazardReport report;
  final ValueChanged<HazardReport> onChanged;
  @override
  State<CommunityReviewDialog> createState() => _CommunityReviewDialogState();
}

class _CommunityReviewDialogState extends State<CommunityReviewDialog> {
  CommunityReview? _review;
  final _reason = TextEditingController();
  String? _error;
  String? _message;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await CommunityRepository(widget.client)
          .summary(widget.report.id);
      if (mounted) setState(() => _review = r);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is StateError
              ? e.message
              : 'Unable to load community reviews.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _vote(String choice) async {
    if (_busy || _review == null) return;
    if (_reason.text.trim().length < 5) {
      setState(() => _error = 'Give a reason with at least 5 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await CommunityRepository(widget.client)
          .review(_review!, choice, _reason.text);
      if (!mounted) return;
      setState(() {
        _review = r;
        _message = r.changed
            ? 'Community consensus recorded. Report updated.'
            : 'Your review was recorded. Three agreeing reviews are required.';
      });
      widget.onChanged(r.report);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is StateError
              ? e.message
              : 'Unable to save your review. Refresh and retry.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _review, report = data?.report ?? widget.report;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        scrollable: true,
        title: const Text('Community review'),
        content: SizedBox(
          width: 580,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                report.type.label,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              SelectableText(report.description),
              Text('School: ${report.schoolName ?? report.schoolId}'),
              Text(
                'Status: ${report.status.label} · Severity: ${report.severity}/5',
              ),
              Text(
                'Reported location: ${report.latitude?.toStringAsFixed(6)}, ${report.longitude?.toStringAsFixed(6)}',
              ),
              if (report.photoSignedUrl case final url?) ...[
                const SizedBox(height: 12),
                HazardPhotoView(url: url),
              ],
              const Divider(height: 28),
              const Text(
                'Share what you observed. Three agreeing reviews from independent network connections change the status. One review per browser and connection in each round; you can revise your own vote. A new round has a 15-minute cooldown after a decision.',
              ),
              const SizedBox(height: 8),
              const Text(
                'Community agreement is not professional verification or a safety guarantee. Reviews cannot prove that each visitor is a different person.',
              ),
              if (data != null) ...[
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    for (final entry in {
                      'verified': 'Concern exists',
                      'resolved': 'Resolved',
                      'rejected': 'Not accurate',
                      'flags': 'Flags',
                    }.entries)
                      Chip(
                        label: Text('${entry.value}: ${data.count(entry.key)}'),
                      ),
                  ],
                ),
                if (data.ownChoice != null)
                  Text(
                    'Your current review: ${{'verified': 'Concern exists', 'resolved': 'Resolved', 'rejected': 'Not accurate', 'flag': 'Flagged'}[data.ownChoice]}',
                  ),
                if (!data.canReview)
                  const Text(
                    'You can follow this report, but cannot review your own submission.',
                  ),
                if (data.canReview) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _reason,
                    enabled: !_busy,
                    minLines: 2,
                    maxLines: 4,
                    maxLength: 500,
                    decoration: const InputDecoration(
                      labelText: 'Reason for your review',
                      helperText: 'No names, home addresses or recurring travel details.',
                      helperMaxLines: 2,
                    ),
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final entry in {
                        'verified': 'Concern exists',
                        'resolved': 'Resolved',
                        'rejected': 'Not accurate',
                        'flag': 'Flag concern',
                      }.entries)
                        OutlinedButton(
                          onPressed: _busy || entry.key == report.status.name
                              ? null
                              : () => _vote(entry.key),
                          child: Text(entry.value),
                        ),
                    ],
                  ),
                ],
              ],
              if (_busy) const LinearProgressIndicator(),
              if (_message != null)
                Semantics(liveRegion: true, child: Text(_message!)),
              if (_error != null)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : _load,
            child: const Text('Refresh'),
          ),
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

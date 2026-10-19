import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/hazard_report.dart';
import '../models/report_moderation.dart';
import '../widgets/hazard_photo_view.dart';

class ReportReviewDialog extends StatefulWidget {
  const ReportReviewDialog({
    super.key,
    required this.report,
    required this.loadData,
    required this.canViewHistory,
    this.onFlag,
    this.onModerate,
    this.onDelete,
  });

  final HazardReport report;
  final Future<ReportReviewData> Function() loadData;
  final bool canViewHistory;
  final Future<void> Function(String reason)? onFlag;
  final Future<void> Function(ReportStatus status, String reason)? onModerate;
  final Future<void> Function()? onDelete;

  @override
  State<ReportReviewDialog> createState() => _ReportReviewDialogState();
}

class _ReportReviewDialogState extends State<ReportReviewDialog> {
  final _formKey = GlobalKey<FormState>();
  final _reason = TextEditingController();
  ReportReviewData? _data;
  String? _error;
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
      _data = null;
      _error = null;
    });
    try {
      final data = await widget.loadData();
      if (mounted) setState(() => _data = data);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Unable to load review details. Try again.');
      }
    }
  }

  Future<void> _save(ReportStatus? status) async {
    if (_busy || !_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (status == null) {
        await widget.onFlag!(_reason.text.trim());
      } else {
        await widget.onModerate!(status, _reason.text.trim());
      }
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = switch (error) {
            PostgrestException(code: '23505') =>
              'You have already flagged this report.',
            PostgrestException(code: '42501') =>
              'Your account does not have access. Sign in and refresh.',
            PostgrestException(code: 'P0001', :final message) => message,
            StateError(:final message) => message,
            _ => 'Unable to save. Check your connection and try again.',
          },
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (_busy || widget.onDelete == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this report?'),
        content: const Text(
          'The report and its stored photo evidence will be permanently removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete report'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onDelete!();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Unable to delete: $error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _date(DateTime date) => date.toLocal().toString().split('.').first;

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final data = _data;
    final openFlags = data?.flags.where((f) => f.isOpen).length ?? 0;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        scrollable: true,
        title: const Text('Report review'),
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
              const SizedBox(height: 12),
              Text(
                'Status: ${report.status.label} · Severity: ${report.severity}/5',
              ),
              Text('Submitted: ${_date(report.createdAt)}'),
              Text('School: ${report.schoolId}'),
              SelectableText('Report ID: ${report.id}'),
              Text(
                report.hasLocation
                    ? 'Location: ${report.latitude!.toStringAsFixed(6)}, ${report.longitude!.toStringAsFixed(6)}'
                    : 'No map location provided',
              ),
              if (report.isDemo) const Text('Fictional example · Demo only'),
              if (report.photoSignedUrl case final url?) ...[
                const SizedBox(height: 16),
                HazardPhotoView(url: url),
              ] else if (report.hasPhoto) ...[
                const SizedBox(height: 16),
                const Text(
                  'Photo evidence is attached but its temporary link is unavailable. Refresh and try again.',
                ),
              ],
              const Divider(height: 28),
              if (data == null && _error == null)
                const LinearProgressIndicator(),
              if (_error != null) ...[
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                if (data == null)
                  TextButton(onPressed: _load, child: const Text('Retry')),
              ],
              if (data != null) ...[
                Text(
                  'Accuracy flags',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (data.flags.isEmpty)
                  const Text('No flags visible to your account.'),
                for (final flag in data.flags)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '${flag.isOpen ? 'Open' : 'Reviewed'} · ${_date(flag.createdAt)}\n${flag.reason}',
                    ),
                  ),
                const SizedBox(height: 20),
                Text(
                  'Moderation history',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (!widget.canViewHistory)
                  const Text(
                    'Decision history is visible to the report author and moderators.',
                  )
                else if (data.history.isEmpty)
                  const Text('No moderation decisions yet.')
                else
                  for (final event in data.history)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${event.previousStatus.label} → ${event.status.label}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          Text(event.reason),
                          Text(
                            '${_date(event.createdAt)} · Moderator: ${event.actorId ?? 'Deleted account'}',
                          ),
                        ],
                      ),
                    ),
                if (widget.onFlag != null || widget.onModerate != null) ...[
                  const Divider(height: 28),
                  Form(
                    key: _formKey,
                    child: TextFormField(
                      controller: _reason,
                      minLines: 2,
                      maxLines: 4,
                      maxLength: 500,
                      enabled: !_busy,
                      decoration: InputDecoration(
                        labelText: widget.onModerate != null
                            ? 'Decision or flag reason'
                            : 'Why is this report inaccurate?',
                        helperText:
                            'Use 5–500 characters. Avoid personal information.',
                        helperMaxLines: 2,
                      ),
                      validator: (value) => (value?.trim().length ?? 0) < 5
                          ? 'Enter a reason with at least 5 characters.'
                          : null,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (widget.onModerate != null)
                        for (final entry in {
                          ReportStatus.verified: 'Verify',
                          ReportStatus.rejected: 'Reject',
                          ReportStatus.resolved: 'Resolve',
                        }.entries)
                          FilledButton.tonal(
                            onPressed:
                                _busy ||
                                    (report.status == entry.key &&
                                        openFlags == 0)
                                ? null
                                : () => _save(entry.key),
                            child: Text(entry.value),
                          ),
                      if (widget.onFlag != null)
                        OutlinedButton.icon(
                          onPressed: _busy ? null : () => _save(null),
                          icon: const Icon(Icons.flag_outlined),
                          label: const Text('Flag inaccurate'),
                        ),
                    ],
                  ),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: LinearProgressIndicator(),
                    ),
                ] else if (report.status == ReportStatus.unverified ||
                    report.status == ReportStatus.verified)
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: Text(
                      'Sign in to flag inaccuracies. Each account can flag a report once.',
                    ),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          if (widget.onDelete != null)
            TextButton.icon(
              onPressed: _busy ? null : _delete,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete report'),
            ),
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

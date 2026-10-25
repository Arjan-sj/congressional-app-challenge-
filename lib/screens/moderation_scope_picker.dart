import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/moderation_queue.dart';
import '../services/moderation_repository.dart';

class ModerationScopePicker extends StatefulWidget {
  const ModerationScopePicker({
    super.key,
    required this.repository,
    required this.kind,
    this.districtId,
    this.onAccessLost,
  });
  final ModerationRepository repository;
  final String kind;
  final String? districtId;
  final VoidCallback? onAccessLost;
  @override
  State<ModerationScopePicker> createState() => _ModerationScopePickerState();
}

class _ModerationScopePickerState extends State<ModerationScopePicker> {
  final _search = TextEditingController();
  final _items = <ModerationScope>[];
  String _cursor = '';
  bool _more = false, _busy = false;
  String? _error;
  Timer? _debounce;
  int _version = 0;
  @override
  void initState() {
    super.initState();
    unawaited(_load(reset: true));
  }

  @override
  void dispose() {
    _version++;
    _search.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    final version = ++_version;
    setState(() {
      _busy = true;
      _error = null;
      if (reset) {
        _items.clear();
        _cursor = '';
        _more = false;
      }
    });
    try {
      final page = await widget.repository.searchScopes(
        widget.kind,
        query: _search.text.trim(),
        districtId: widget.districtId,
        afterId: _cursor,
      );
      if (!mounted || version != _version) return;
      setState(() {
        _items.addAll(page.items);
        _cursor = page.cursor ?? '';
        _more = page.hasMore;
      });
    } on PostgrestException catch (error) {
      if (!mounted || version != _version) return;
      if (error.code == '42501') {
        Navigator.pop(context);
        widget.onAccessLost?.call();
        return;
      }
      setState(() => _error = 'Unable to search. Retry.');
    } catch (_) {
      if (mounted && version == _version) {
        setState(() => _error = 'Unable to search. Retry.');
      }
    } finally {
      if (mounted && version == _version) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 650, maxHeight: 700),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(
              'Choose ${widget.kind}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            TextField(
              controller: _search,
              maxLength: 120,
              decoration: const InputDecoration(
                labelText: 'Search name, state or ID',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (_) {
                _version++;
                _debounce?.cancel();
                setState(() {
                  _items.clear();
                  _busy = true;
                  _more = false;
                });
                _debounce = Timer(
                  const Duration(milliseconds: 300),
                  () => _load(reset: true),
                );
              },
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Wrap(
                children: [
                  Text(_error!),
                  TextButton(
                    onPressed: () => _load(),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            Expanded(
              child: ListView.builder(
                itemCount: _items.length + 1,
                itemBuilder: (context, index) {
                  if (index == _items.length) {
                    return _more
                        ? TextButton(
                            onPressed: _busy ? null : () => _load(),
                            child: const Text('Load more'),
                          )
                        : Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              _busy
                                  ? 'Loading…'
                                  : _items.isEmpty
                                  ? 'No matching results.'
                                  : 'End of results.',
                            ),
                          );
                  }
                  final s = _items[index];
                  return ListTile(
                    title: Text(s.name),
                    subtitle: Text(
                      [
                        s.city,
                        s.state,
                        s.id,
                      ].where((v) => v.isNotEmpty).join(' · '),
                    ),
                    onTap: () => Navigator.pop(context, (scope: s)),
                  );
                },
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, (scope: null)),
                  child: Text('All ${widget.kind}s'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

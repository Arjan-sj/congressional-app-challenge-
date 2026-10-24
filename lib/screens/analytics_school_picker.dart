import 'dart:async';

import 'package:flutter/material.dart';

import '../models/analytics.dart';
import '../services/analytics_repository.dart';

/// Server search with keyset paging across the entire canonical directory.
class AnalyticsSchoolPicker extends StatefulWidget {
  const AnalyticsSchoolPicker({
    super.key,
    required this.repository,
    required this.selected,
  });
  final AnalyticsRepository repository;
  final Set<String> selected;
  @override
  State<AnalyticsSchoolPicker> createState() => _AnalyticsSchoolPickerState();
}

class _AnalyticsSchoolPickerState extends State<AnalyticsSchoolPicker> {
  late final Set<String> _selected = {...widget.selected};
  List<AnalyticsSchoolOption> _schools = [];
  String _query = '';
  String? _error;
  bool _loading = false;
  bool _more = false;
  int _version = 0;
  Timer? _debounce;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    final version = ++_version;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await widget.repository.fetchSchools(
        query: _query,
        afterId: more && _schools.isNotEmpty ? _schools.last.id : '',
      );
      if (!mounted || version != _version) return;
      setState(() {
        _schools = more ? [..._schools, ...rows] : rows;
        _more = rows.length == 100;
      });
    } catch (_) {
      if (mounted && version == _version) {
        setState(() => _error = 'Could not search schools. Retry.');
      }
    } finally {
      if (mounted && version == _version) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Filter by school'),
    content: SizedBox(
      width: 520,
      height: 460,
      child: Column(
        children: [
          TextField(
            autofocus: true,
            maxLength: 120,
            decoration: const InputDecoration(
              labelText: 'Search nationwide schools',
              hintText: 'Name, city, state, ZIP, or district',
            ),
            onChanged: (value) {
              _debounce?.cancel();
              ++_version;
              setState(() {
                _query = value.trim();
                _schools = [];
                _loading = true;
                _more = false;
              });
              _debounce = Timer(
                const Duration(milliseconds: 300),
                () => _load(),
              );
            },
          ),
          Text('${_selected.length} schools selected'),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            TextButton(onPressed: () => _load(), child: Text(_error!)),
          Expanded(
            child: ListView(
              children: [
                if (!_loading && _error == null && _schools.isEmpty)
                  const Text('No schools match.'),
                for (final school in _schools)
                  CheckboxListTile(
                    value: _selected.contains(school.id),
                    title: Text(school.name),
                    subtitle: Text(
                      '${school.city ?? ''}, ${school.state ?? ''} • ${school.district}',
                    ),
                    onChanged: (checked) => setState(() {
                      checked == true
                          ? _selected.add(school.id)
                          : _selected.remove(school.id);
                    }),
                  ),
                if (_more)
                  TextButton(
                    onPressed: _loading ? null : () => _load(more: true),
                    child: const Text('Load more schools'),
                  ),
              ],
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
        onPressed: () => Navigator.pop(context, _selected),
        child: const Text('Apply'),
      ),
    ],
  );
}

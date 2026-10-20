import 'package:flutter/material.dart';

import '../models/school.dart';

/// Paged detail for dense/co-located schools, including at the maximum map zoom.
class SchoolClusterPanel extends StatefulWidget {
  const SchoolClusterPanel({
    super.key,
    required this.load,
    required this.onSelect,
  });
  final Future<List<School>> Function(String? after) load;
  final ValueChanged<School> onSelect;
  @override
  State<SchoolClusterPanel> createState() => _SchoolClusterPanelState();
}

class _SchoolClusterPanelState extends State<SchoolClusterPanel> {
  final List<School> _schools = [];
  bool _loading = false, _more = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    _next();
  }

  Future<void> _next() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.load(_schools.lastOrNull?.id);
      if (!mounted) return;
      setState(() {
        _schools.addAll(page);
        _more = page.length == 100;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not load school details. Retry.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Schools in this area',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final school in _schools)
                ListTile(
                  leading: const Icon(Icons.school),
                  title: Text(school.name),
                  subtitle: Text(school.address),
                  onTap: () => widget.onSelect(school),
                ),
              if (_loading) const LinearProgressIndicator(),
              if (_error != null)
                TextButton(onPressed: _next, child: Text(_error!))
              else if (_more && !_loading)
                TextButton(
                  onPressed: _next,
                  child: const Text('Load more schools'),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

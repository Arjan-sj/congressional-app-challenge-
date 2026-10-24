import 'package:flutter/material.dart';

import '../models/school_district.dart';

/// Searches the complete district directory while building visible rows only.
class AnalyticsDistrictPicker extends StatefulWidget {
  const AnalyticsDistrictPicker({
    super.key,
    required this.districts,
    required this.selected,
  });

  final List<AnalyticsDistrictOption> districts;
  final Set<String> selected;

  @override
  State<AnalyticsDistrictPicker> createState() =>
      _AnalyticsDistrictPickerState();
}

class _AnalyticsDistrictPickerState extends State<AnalyticsDistrictPicker> {
  late final Set<String> _selected = {...widget.selected};
  late final List<String> _searchText = [
    for (final district in widget.districts)
      '${district.name} ${district.state ?? ''} ${district.id}'.toLowerCase(),
  ];
  late List<AnalyticsDistrictOption> _matching = widget.districts;

  void _search(String value) {
    final query = value.trim().toLowerCase();
    setState(() {
      _matching = query.isEmpty
          ? widget.districts
          : [
              for (var i = 0; i < widget.districts.length; i++)
                if (_searchText[i].contains(query)) widget.districts[i],
            ];
    });
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Filter by district',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextField(
              autofocus: true,
              maxLength: 120,
              decoration: const InputDecoration(
                labelText: 'Search districts',
                hintText: 'Name, state, or NCES ID',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: _search,
            ),
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(
                '${_selected.length} selected · ${_matching.length} matches',
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _matching.isEmpty
                  ? const Center(child: Text('No districts match.'))
                  : ListView.builder(
                      key: const ValueKey('analytics-district-list'),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: _matching.length,
                      itemBuilder: (context, index) {
                        final district = _matching[index];
                        return CheckboxListTile(
                          key: ValueKey('district-${district.id}'),
                          contentPadding: EdgeInsets.zero,
                          value: _selected.contains(district.id),
                          title: Text(district.displayLabel),
                          onChanged: (checked) => setState(() {
                            checked == true
                                ? _selected.add(district.id)
                                : _selected.remove(district.id);
                          }),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 12,
              runSpacing: 8,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, <String>{}),
                  child: const Text('Clear'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, _selected),
                  child: const Text('Apply'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

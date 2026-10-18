import 'package:flutter/material.dart';

import '../models/hazard_report.dart';

class ReportFormScreen extends StatefulWidget {
  const ReportFormScreen({super.key, required this.onSubmit});

  final ValueChanged<HazardReport> onSubmit;

  @override
  State<ReportFormScreen> createState() => _ReportFormScreenState();
}

class _ReportFormScreenState extends State<ReportFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _descriptionController = TextEditingController();
  HazardType _type = HazardType.missingSidewalk;
  double _severity = 3;

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    widget.onSubmit(HazardReport(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      schoolId: 'sample-school',
      type: _type,
      severity: _severity.round(),
      description: _descriptionController.text.trim(),
      createdAt: DateTime.now(),
      // A real report MUST get an actual map-selected location before
      // being sent to any backend. This demo uses no real coordinates.
    ));

    _descriptionController.clear();
    _formKey.currentState?.reset();
    setState(() {
      _type = HazardType.missingSidewalk;
      _severity = 3;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Create a demo report', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text(
            'For testing only: this does not submit an official report, store data online, or identify a real location.',
          ),
          const SizedBox(height: 20),
          DropdownButtonFormField<HazardType>(
            initialValue: _type,
            decoration: const InputDecoration(labelText: 'Issue type', border: OutlineInputBorder()),
            items: [
              for (final type in HazardType.values)
                DropdownMenuItem(value: type, child: Text(type.label)),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _type = value);
            },
          ),
          const SizedBox(height: 18),
          Text('Reported severity: ${_severity.round()}/5'),
          Slider(
            min: 1,
            max: 5,
            divisions: 4,
            value: _severity,
            label: _severity.round().toString(),
            onChanged: (value) => setState(() => _severity = value),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _descriptionController,
            maxLines: 3,
            maxLength: 250,
            decoration: const InputDecoration(
              labelText: 'Describe a fictional issue',
              border: OutlineInputBorder(),
            ),
            validator: (text) =>
                text == null || text.trim().length < 5 ? 'Write at least 5 characters' : null,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save demo report locally'),
          ),
        ],
      ),
    );
  }
}

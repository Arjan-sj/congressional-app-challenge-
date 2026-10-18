import 'package:flutter/material.dart';
import '../data/pilot_school.dart';
import '../models/hazard_report.dart';

class ReportFormScreen extends StatefulWidget {
  const ReportFormScreen({
    super.key,
    required this.onSubmit,
    required this.onChooseLocation,
    this.selectedLatitude,
    this.selectedLongitude,
    this.isLive = false,
  });
  final Future<void> Function(HazardReport) onSubmit;
  final VoidCallback onChooseLocation;
  final double? selectedLatitude;
  final double? selectedLongitude;
  final bool isLive;

  @override
  State<ReportFormScreen> createState() => _ReportFormScreenState();
}

class _ReportFormScreenState extends State<ReportFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _descriptionController = TextEditingController();
  HazardType _type = HazardType.missingSidewalk;
  double _severity = 3;
  bool _saving = false;

  bool get _hasLocation =>
      widget.selectedLatitude != null && widget.selectedLongitude != null;

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_hasLocation || !_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await widget.onSubmit(HazardReport(
        id: 'local-${DateTime.now().microsecondsSinceEpoch}',
        schoolId: PilotSchool.id,
        type: _type,
        severity: _severity.round(),
        description: _descriptionController.text.trim(),
        createdAt: DateTime.now(),
        latitude: widget.selectedLatitude,
        longitude: widget.selectedLongitude,
      ));
      if (!mounted) return;
      _descriptionController.clear();
      _formKey.currentState?.reset();
      setState(() {
        _type = HazardType.missingSidewalk;
        _severity = 3;
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
          Text(widget.isLive
              ? 'Pilot database mode. Sign in first; example reports are saved '
                  'as unverified. Do not submit real student routes.'
              : 'For testing only: nothing is sent to officials or saved online.'),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: Icon(_hasLocation ? Icons.place : Icons.add_location_alt_outlined),
              title: Text(_hasLocation ? 'Map point selected' : 'Select a point on the map first'),
              subtitle: Text(_hasLocation
                  ? '${widget.selectedLatitude!.toStringAsFixed(5)}, '
                      '${widget.selectedLongitude!.toStringAsFixed(5)}'
                  : 'Return to Explore and tap a location.'),
              trailing: TextButton(
                onPressed: widget.onChooseLocation,
                child: const Text('Choose on map'),
              ),
            ),
          ),
          const SizedBox(height: 16),
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
          Text('Self-reported severity: ${_severity.round()}/5'),
          Slider(
            min: 1, max: 5, divisions: 4,
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
            validator: (text) => text == null || text.trim().length < 5
                ? 'Write at least 5 characters' : null,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _hasLocation && !_saving ? _save : null,
            icon: const Icon(Icons.save_outlined),
            label: Text(_saving ? 'Saving...' :
                widget.isLive ? 'Save example to Supabase' : 'Save demo report locally'),
          ),
        ],
      ),
    );
  }
}

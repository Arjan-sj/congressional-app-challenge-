import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../data/pilot_school.dart';
import '../models/hazard_photo.dart';
import '../models/hazard_report.dart';
import '../widgets/app_ui.dart';

class ReportFormScreen extends StatefulWidget {
  const ReportFormScreen({
    super.key,
    required this.onSubmit,
    required this.onChooseLocation,
    this.selectedLatitude,
    this.selectedLongitude,
    this.isLive = false,
    this.submissionEnabled = true,
    this.pickPhoto,
  });

  final Future<void> Function(
    HazardReport report,
    HazardPhotoDraft? photo,
    ValueChanged<double> onProgress,
  )
  onSubmit;
  final VoidCallback onChooseLocation;
  final double? selectedLatitude;
  final double? selectedLongitude;
  final bool isLive;
  final bool submissionEnabled;
  final Future<HazardPhotoDraft?> Function(ImageSource source)? pickPhoto;

  @override
  State<ReportFormScreen> createState() => _ReportFormScreenState();
}

class _ReportFormScreenState extends State<ReportFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _descriptionController = TextEditingController();
  HazardType _type = HazardType.missingSidewalk;
  double _severity = 3;
  bool _saving = false;
  bool _choosingPhoto = false;
  HazardPhotoDraft? _photo;
  String? _photoError;
  double? _uploadProgress;

  bool get _hasLocation =>
      widget.selectedLatitude != null && widget.selectedLongitude != null;

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  IconData _iconFor(HazardType type) => switch (type) {
    HazardType.missingSidewalk => Icons.directions_walk,
    HazardType.difficultCrossing => Icons.add_road,
    HazardType.blockedPath => Icons.block,
    HazardType.bikeRoute => Icons.pedal_bike,
  };

  Future<void> _choosePhoto(ImageSource source) async {
    if (_choosingPhoto || _saving) return;
    setState(() {
      _choosingPhoto = true;
      _photoError = null;
    });
    try {
      final photo = widget.pickPhoto != null
          ? await widget.pickPhoto!(source)
          : await _pickPhoto(source);
      if (photo != null && mounted) setState(() => _photo = photo);
    } on HazardPhotoException catch (error) {
      if (mounted) setState(() => _photoError = error.message);
    } catch (_) {
      if (mounted) {
        setState(() {
          _photoError = source == ImageSource.camera
              ? 'The camera is unavailable on this device. Upload an existing image instead.'
              : 'The image could not be opened. Try another JPEG, PNG, or WebP file.';
        });
      }
    } finally {
      if (mounted) setState(() => _choosingPhoto = false);
    }
  }

  Future<HazardPhotoDraft?> _pickPhoto(ImageSource source) async {
    final file = await ImagePicker().pickImage(
      source: source,
      maxWidth: 2400,
      imageQuality: 88,
    );
    if (file == null) return null;
    return HazardPhotoDraft.validate(
      bytes: await file.readAsBytes(),
      fileName: file.name,
      declaredMimeType: file.mimeType,
    );
  }

  Future<void> _save() async {
    if (_saving || !_hasLocation || !_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _uploadProgress = _photo == null ? null : 0;
    });
    try {
      await widget.onSubmit(
        HazardReport(
          id: 'local-${DateTime.now().microsecondsSinceEpoch}',
          schoolId: PilotSchool.id,
          type: _type,
          severity: _severity.round(),
          description: _descriptionController.text.trim(),
          createdAt: DateTime.now(),
          latitude: widget.selectedLatitude,
          longitude: widget.selectedLongitude,
          isDemo: false,
        ),
        _photo,
        (progress) {
          if (mounted) {
            setState(() => _uploadProgress = progress.clamp(0, 1).toDouble());
          }
        },
      );

      if (!mounted) return;
      _descriptionController.clear();
      _formKey.currentState?.reset();
      setState(() {
        _type = HazardType.missingSidewalk;
        _severity = 3;
        _photo = null;
        _photoError = null;
        _uploadProgress = null;
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not save: $error')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _uploadProgress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Form(
      key: _formKey,
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 780),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const PageIntro(
                          eyebrow: 'Share an observation',
                          title: 'Report a walking or biking concern',
                          description: 'Choose a location, describe what you observed, and submit it for review.',
                          icon: Icons.add_location_alt_outlined,
                        ),
                        const SizedBox(height: 22),
                        Container(
                          padding: const EdgeInsets.all(15),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF7E8),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: const Color(0xFFF1D9A7)),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.science_outlined,
                                color: Color(0xFF795300),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  widget.isLive
                                      ? 'Reports are saved as unverified until a moderator reviews them. Never include student names, home addresses, or recurring travel details.'
                                      : 'Supabase is not configured, so report submission is unavailable. The map and route tools remain usable.',
                                  style: const TextStyle(
                                    color: Color(0xFF604300),
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        SectionCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const _StepLabel(
                                number: '1',
                                label: 'Choose a location',
                              ),
                              const SizedBox(height: 16),
                              Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: _hasLocation
                                      ? colors.primaryContainer.withValues(
                                          alpha: .55,
                                        )
                                      : colors.surfaceContainer,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: _hasLocation
                                        ? colors.primary.withValues(alpha: .35)
                                        : colors.outlineVariant,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 44,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        color: _hasLocation
                                            ? colors.primary
                                            : Colors.white,
                                        borderRadius: BorderRadius.circular(13),
                                      ),
                                      child: Icon(
                                        _hasLocation
                                            ? Icons.check_rounded
                                            : Icons.add_location_alt_outlined,
                                        color: _hasLocation
                                            ? Colors.white
                                            : colors.primary,
                                      ),
                                    ),
                                    const SizedBox(width: 13),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            _hasLocation
                                                ? 'Map point selected'
                                                : 'Select a point on the map first',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleSmall,
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            _hasLocation
                                                ? '${widget.selectedLatitude!.toStringAsFixed(5)}, '
                                                      '${widget.selectedLongitude!.toStringAsFixed(5)}'
                                                : 'Return to Explore and tap the desired map location.',
                                            style: TextStyle(
                                              color: colors.onSurfaceVariant,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    TextButton.icon(
                                      onPressed: widget.onChooseLocation,
                                      icon: const Icon(
                                        Icons.map_outlined,
                                        size: 18,
                                      ),
                                      label: Text(
                                        _hasLocation
                                            ? 'Change'
                                            : 'Choose on map',
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        SectionCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const _StepLabel(
                                number: '2',
                                label: 'Describe the concern',
                              ),
                              const SizedBox(height: 18),
                              DropdownButtonFormField<HazardType>(
                                initialValue: _type,
                                decoration: InputDecoration(
                                  labelText: 'Issue type',
                                  prefixIcon: Icon(_iconFor(_type)),
                                ),
                                items: [
                                  for (final type in HazardType.values)
                                    DropdownMenuItem(
                                      value: type,
                                      child: Text(type.label),
                                    ),
                                ],
                                onChanged: (value) {
                                  if (value != null) {
                                    setState(() => _type = value);
                                  }
                                },
                              ),
                              const SizedBox(height: 18),
                              TextFormField(
                                controller: _descriptionController,
                                maxLines: 4,
                                maxLength: 250,
                                decoration: const InputDecoration(
                                  labelText: 'Describe the concern',
                                  alignLabelWithHint: true,
                                  prefixIcon: Padding(
                                    padding: EdgeInsets.only(bottom: 70),
                                    child: Icon(Icons.notes_outlined),
                                  ),
                                  hintText: 'What would someone walking or biking notice?',
                                ),
                                validator: (text) =>
                                    text == null || text.trim().length < 5
                                    ? 'Write at least 5 characters'
                                    : null,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        SectionCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const _StepLabel(
                                number: '3',
                                label: 'Set the severity',
                              ),
                              const SizedBox(height: 18),
                              Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Self-reported severity',
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleSmall,
                                        ),
                                        Text(
                                          '1 is minor, 5 needs the most attention',
                                          style: TextStyle(
                                            color: colors.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Container(
                                    width: 54,
                                    height: 54,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: colors.primaryContainer,
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: Text(
                                      '${_severity.round()}/5',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            color: colors.primary,
                                            fontWeight: FontWeight.w800,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                              Slider(
                                min: 1,
                                max: 5,
                                divisions: 4,
                                value: _severity,
                                label: _severity.round().toString(),
                                onChanged: (value) =>
                                    setState(() => _severity = value),
                              ),
                              const Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text('Minor'),
                                  Text('Needs attention'),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        SectionCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const _StepLabel(
                                number: '4',
                                label: 'Add photo evidence (optional)',
                              ),
                              const SizedBox(height: 10),
                              Text(
                                'JPEG, PNG, or WebP • maximum 5 MB. Avoid faces, license plates, student names, and home addresses.',
                                style: TextStyle(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 14),
                              if (_photo case final photo?) ...[
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: Image.memory(
                                    photo.bytes,
                                    key: const ValueKey('photo-preview'),
                                    width: double.infinity,
                                    height: 250,
                                    fit: BoxFit.cover,
                                    semanticLabel: 'Selected hazard photo',
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  '${photo.fileName} • ${photo.sizeMegabytes.toStringAsFixed(1)} MB',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 10),
                              ],
                              Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: _choosingPhoto || _saving
                                        ? null
                                        : () =>
                                              _choosePhoto(ImageSource.camera),
                                    icon: const Icon(
                                      Icons.photo_camera_outlined,
                                    ),
                                    label: Text(
                                      _photo == null
                                          ? 'Take photo'
                                          : 'Replace with camera',
                                    ),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: _choosingPhoto || _saving
                                        ? null
                                        : () =>
                                              _choosePhoto(ImageSource.gallery),
                                    icon: const Icon(
                                      Icons.upload_file_outlined,
                                    ),
                                    label: Text(
                                      _photo == null
                                          ? 'Upload image'
                                          : 'Replace image',
                                    ),
                                  ),
                                  if (_photo != null)
                                    TextButton.icon(
                                      onPressed: _saving
                                          ? null
                                          : () => setState(() {
                                              _photo = null;
                                              _photoError = null;
                                            }),
                                      icon: const Icon(Icons.delete_outline),
                                      label: const Text('Remove'),
                                    ),
                                ],
                              ),
                              if (_choosingPhoto) ...[
                                const SizedBox(height: 12),
                                const LinearProgressIndicator(),
                              ],
                              if (_photoError != null) ...[
                                const SizedBox(height: 10),
                                Text(
                                  _photoError!,
                                  style: TextStyle(color: colors.error),
                                ),
                              ],
                              if (_saving && _photo != null) ...[
                                const SizedBox(height: 14),
                                LinearProgressIndicator(value: _uploadProgress),
                                const SizedBox(height: 6),
                                Text(
                                  _uploadProgress == null ||
                                          _uploadProgress! < .25
                                      ? 'Preparing secure photo upload…'
                                      : _uploadProgress! < 1
                                      ? 'Uploading photo evidence…'
                                      : 'Photo uploaded',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
            decoration: BoxDecoration(
              color: colors.surface,
              border: Border(top: BorderSide(color: colors.outlineVariant)),
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 780),
                child: Row(
                  children: [
                    if (!widget.submissionEnabled) ...[
                      Icon(
                        Icons.cloud_off_outlined,
                        size: 18,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Configure Supabase to enable submissions.',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ),
                    ] else if (!_hasLocation) ...[
                      Icon(
                        Icons.info_outline,
                        size: 18,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Choose a map location to enable saving.',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ),
                    ] else
                      const Spacer(),
                    FilledButton.icon(
                      onPressed:
                          widget.submissionEnabled && _hasLocation && !_saving
                          ? _save
                          : null,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(
                        _saving
                            ? 'Saving...'
                            : widget.isLive
                            ? 'Submit unverified report'
                            : 'Supabase not configured',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StepLabel extends StatelessWidget {
  const _StepLabel({required this.number, required this.label});

  final String number;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colors.primary,
            shape: BoxShape.circle,
          ),
          child: Text(
            number,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(label, style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }
}

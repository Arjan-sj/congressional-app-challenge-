import 'package:flutter/material.dart';

import '../models/accessibility_preferences.dart';

class AccessibilitySettingsDialog extends StatefulWidget {
  const AccessibilitySettingsDialog({
    super.key,
    required this.initialPreferences,
  });

  final AccessibilityPreferences initialPreferences;

  @override
  State<AccessibilitySettingsDialog> createState() =>
      _AccessibilitySettingsDialogState();
}

class _AccessibilitySettingsDialogState
    extends State<AccessibilitySettingsDialog> {
  late AccessibilityPreferences _preferences;

  @override
  void initState() {
    super.initState();
    _preferences = widget.initialPreferences;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: const Icon(Icons.accessibility_new),
    title: const Text('Accessibility settings'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _choice(
              title: 'Larger text',
              subtitle: 'Use at least 125% text throughout the app.',
              value: _preferences.largerText,
              onChanged: (value) =>
                  _update(_preferences.copyWith(largerText: value)),
            ),
            _choice(
              title: 'Higher contrast colors',
              subtitle: 'Increase contrast for text, borders, and controls.',
              value: _preferences.highContrast,
              onChanged: (value) =>
                  _update(_preferences.copyWith(highContrast: value)),
            ),
            _choice(
              title: 'Larger controls',
              subtitle: 'Increase button and navigation target sizes.',
              value: _preferences.largerControls,
              onChanged: (value) =>
                  _update(_preferences.copyWith(largerControls: value)),
            ),
            _choice(
              title: 'Keyboard map navigation',
              subtitle: 'Use arrow keys to pan and plus or minus to zoom.',
              value: _preferences.keyboardMapNavigation,
              onChanged: (value) =>
                  _update(_preferences.copyWith(keyboardMapNavigation: value)),
            ),
            _choice(
              title: 'Show map information as text',
              subtitle: 'List visible schools, hazards, and coordinates.',
              value: _preferences.showMapText,
              onChanged: (value) =>
                  _update(_preferences.copyWith(showMapText: value)),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () =>
            setState(() => _preferences = const AccessibilityPreferences()),
        child: const Text('Reset'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _preferences),
        child: const Text('Save choices'),
      ),
    ],
  );

  Widget _choice({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: Text(subtitle),
    value: value,
    onChanged: onChanged,
  );

  void _update(AccessibilityPreferences preferences) {
    setState(() => _preferences = preferences);
  }
}

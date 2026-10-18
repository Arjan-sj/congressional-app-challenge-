import 'package:shared_preferences/shared_preferences.dart';

import '../models/accessibility_preferences.dart';

class AccessibilityPreferencesStore {
  const AccessibilityPreferencesStore();

  static const _largerText = 'accessibility.larger_text';
  static const _highContrast = 'accessibility.high_contrast';
  static const _largerControls = 'accessibility.larger_controls';
  static const _keyboardMap = 'accessibility.keyboard_map';
  static const _mapText = 'accessibility.map_text';

  Future<AccessibilityPreferences> load() async {
    final storage = await SharedPreferences.getInstance();
    return AccessibilityPreferences(
      largerText: storage.getBool(_largerText) ?? false,
      highContrast: storage.getBool(_highContrast) ?? false,
      largerControls: storage.getBool(_largerControls) ?? false,
      keyboardMapNavigation: storage.getBool(_keyboardMap) ?? false,
      showMapText: storage.getBool(_mapText) ?? false,
    );
  }

  Future<void> save(AccessibilityPreferences preferences) async {
    final storage = await SharedPreferences.getInstance();
    await Future.wait([
      storage.setBool(_largerText, preferences.largerText),
      storage.setBool(_highContrast, preferences.highContrast),
      storage.setBool(_largerControls, preferences.largerControls),
      storage.setBool(_keyboardMap, preferences.keyboardMapNavigation),
      storage.setBool(_mapText, preferences.showMapText),
    ]);
  }
}

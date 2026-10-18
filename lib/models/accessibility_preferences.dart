class AccessibilityPreferences {
  const AccessibilityPreferences({
    this.largerText = false,
    this.highContrast = false,
    this.largerControls = false,
    this.keyboardMapNavigation = false,
    this.showMapText = false,
  });

  final bool largerText;
  final bool highContrast;
  final bool largerControls;
  final bool keyboardMapNavigation;
  final bool showMapText;

  bool get hasEnabledChoices =>
      largerText ||
      highContrast ||
      largerControls ||
      keyboardMapNavigation ||
      showMapText;

  AccessibilityPreferences copyWith({
    bool? largerText,
    bool? highContrast,
    bool? largerControls,
    bool? keyboardMapNavigation,
    bool? showMapText,
  }) => AccessibilityPreferences(
    largerText: largerText ?? this.largerText,
    highContrast: highContrast ?? this.highContrast,
    largerControls: largerControls ?? this.largerControls,
    keyboardMapNavigation: keyboardMapNavigation ?? this.keyboardMapNavigation,
    showMapText: showMapText ?? this.showMapText,
  );
}

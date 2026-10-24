import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models/accessibility_preferences.dart';
import 'screens/home_screen.dart';
import 'services/accessibility_preferences_store.dart';

class SafeRoutesApp extends StatefulWidget {
  const SafeRoutesApp({
    super.key,
    this.enableMapTiles = true,
    this.liveClient,
    this.persistAccessibilityPreferences = true,
    this.enableLiveUpdates = true,
  });

  /// false in widget tests to keep them independent of network map tiles.
  final bool enableMapTiles;
  final SupabaseClient? liveClient;
  final bool persistAccessibilityPreferences;
  final bool enableLiveUpdates;

  @override
  State<SafeRoutesApp> createState() => _SafeRoutesAppState();
}

class _SafeRoutesAppState extends State<SafeRoutesApp> {
  static const _store = AccessibilityPreferencesStore();
  AccessibilityPreferences _preferences = const AccessibilityPreferences();

  @override
  void initState() {
    super.initState();
    if (widget.persistAccessibilityPreferences) {
      unawaited(_loadPreferences());
    }
  }

  Future<void> _loadPreferences() async {
    try {
      final loaded = await _store.load();
      if (mounted) setState(() => _preferences = loaded);
    } catch (_) {
      // Keep defaults when local storage is unavailable.
    }
  }

  void _updatePreferences(AccessibilityPreferences preferences) {
    setState(() => _preferences = preferences);
    if (widget.persistAccessibilityPreferences) {
      unawaited(_savePreferences(preferences));
    }
  }

  Future<void> _savePreferences(AccessibilityPreferences preferences) async {
    try {
      await _store.save(preferences);
    } catch (_) {
      // The active choices still apply for this session.
    }
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF087F72);
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
      contrastLevel: _preferences.highContrast ? .5 : 0,
      surface: const Color(0xFFF7FAF9),
    );

    return MaterialApp(
      title: 'SafeRoutes',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        materialTapTargetSize: MaterialTapTargetSize.padded,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFFF3F7F6),
        textTheme: const TextTheme(
          headlineLarge: TextStyle(
            fontSize: 40,
            height: 1.08,
            fontWeight: FontWeight.w800,
            letterSpacing: -1.1,
          ),
          headlineMedium: TextStyle(
            fontSize: 30,
            height: 1.12,
            fontWeight: FontWeight.w800,
            letterSpacing: -.65,
          ),
          headlineSmall: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            letterSpacing: -.35,
          ),
          titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          bodyLarge: TextStyle(fontSize: 16),
        ),
        appBarTheme: AppBarTheme(
          elevation: 0,
          scrolledUnderElevation: 0,
          backgroundColor: const Color(0xFFF7FAF9),
          foregroundColor: colorScheme.onSurface,
          surfaceTintColor: Colors.transparent,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: colorScheme.onSurface,
            fontSize: 20,
            fontWeight: FontWeight.w800,
            letterSpacing: -.3,
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: Colors.white,
          surfaceTintColor: Colors.transparent,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: const Color(0xFFDAE5E2)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 17,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: colorScheme.outlineVariant),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: colorScheme.outlineVariant),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: colorScheme.primary, width: 2),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 50),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
            minimumSize: Size.square(_preferences.largerControls ? 56 : 48),
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          height: 72,
          backgroundColor: Colors.white,
          elevation: 0,
          indicatorColor: colorScheme.primaryContainer,
          labelTextStyle: WidgetStateProperty.resolveWith(
            (states) => TextStyle(
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w700
                  : FontWeight.w500,
              color: states.contains(WidgetState.selected)
                  ? colorScheme.primary
                  : colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
      builder: (context, child) {
        if (!_preferences.largerText) return child!;
        final media = MediaQuery.of(context);
        final systemScale = media.textScaler.scale(1);
        return MediaQuery(
          data: media.copyWith(
            textScaler: TextScaler.linear(
              systemScale < 1.25 ? 1.25 : systemScale,
            ),
          ),
          child: child!,
        );
      },
      home: HomeScreen(
        enableLiveUpdates: widget.enableLiveUpdates,
        enableMapTiles: widget.enableMapTiles,
        liveClient: widget.liveClient,
        accessibilityPreferences: _preferences,
        onAccessibilityPreferencesChanged: _updatePreferences,
      ),
    );
  }
}

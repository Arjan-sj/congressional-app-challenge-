import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

class SafeRoutesApp extends StatelessWidget {
  const SafeRoutesApp({super.key, this.enableMapTiles = true});

  /// false in widget tests to keep them independent of network map tiles.
  final bool enableMapTiles;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SafeRoutes',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF167D6D),
        ),
      ),
      home: HomeScreen(enableMapTiles: enableMapTiles),
    );
  }
}

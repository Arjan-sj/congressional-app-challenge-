import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'screens/home_screen.dart';

class SafeRoutesApp extends StatelessWidget {
  const SafeRoutesApp({super.key, this.enableMapTiles = true, this.liveClient});

  final bool enableMapTiles;
  final SupabaseClient? liveClient;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SafeRoutes',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF167D6D)),
      ),
      home: HomeScreen(enableMapTiles: enableMapTiles, liveClient: liveClient),
    );
  }
}

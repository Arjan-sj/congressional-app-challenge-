import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const ChallengeApp());
}

class ChallengeApp extends StatelessWidget {
  const ChallengeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Challenge App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3157D5),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF7F8FC),
      ),
      home: const HomeScreen(),
    );
  }
}

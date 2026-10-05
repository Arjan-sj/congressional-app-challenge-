import 'package:flutter/material.dart';

class PrototypeScreen extends StatefulWidget {
  const PrototypeScreen({super.key});

  @override
  State<PrototypeScreen> createState() => _PrototypeScreenState();
}

class _PrototypeScreenState extends State<PrototypeScreen> {
  int demoCount = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Prototype'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Main Feature Placeholder',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 8),
            const Text(
              'This page is where the core function of your app should live.',
            ),
            const SizedBox(height: 28),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    const Icon(Icons.construction, size: 48),
                    const SizedBox(height: 12),
                    Text(
                      'Demo interactions: $demoCount',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: () {
                        setState(() => demoCount++);
                      },
                      icon: const Icon(Icons.add),
                      label: const Text('Test Interaction'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

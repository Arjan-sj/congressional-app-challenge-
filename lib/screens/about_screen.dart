import 'package:flutter/material.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('About'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: const [
          _InfoSection(
            title: 'Problem',
            body:
                'Describe the real problem your app is trying to solve. Be specific about who experiences it and why existing solutions are not enough.',
          ),
          SizedBox(height: 16),
          _InfoSection(
            title: 'Solution',
            body:
                'Explain what your app does differently and how the user benefits from it.',
          ),
          SizedBox(height: 16),
          _InfoSection(
            title: 'Impact',
            body:
                'Describe what changes if people actually use your app. Try to make this measurable.',
          ),
        ],
      ),
    );
  }
}

class _InfoSection extends StatelessWidget {
  final String title;
  final String body;

  const _InfoSection({
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 8),
            Text(body),
          ],
        ),
      ),
    );
  }
}

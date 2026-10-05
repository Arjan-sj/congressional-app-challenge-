import 'package:flutter/material.dart';
import '../widgets/feature_card.dart';
import 'about_screen.dart';
import 'prototype_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Challenge App',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        centerTitle: false,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'Build something useful.',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'This starter gives you a clean base for your Congressional App Challenge project.',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Colors.black54,
                    height: 1.4,
                  ),
            ),
            const SizedBox(height: 28),
            FeatureCard(
              icon: Icons.rocket_launch_outlined,
              title: 'Prototype',
              description: 'Replace this screen with the main feature of your app.',
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const PrototypeScreen(),
                  ),
                );
              },
            ),
            const SizedBox(height: 14),
            FeatureCard(
              icon: Icons.info_outline,
              title: 'About the Project',
              description: 'Explain the problem, your solution, and why it matters.',
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const AboutScreen(),
                  ),
                );
              },
            ),
            const SizedBox(height: 30),
            const _NextStepCard(),
          ],
        ),
      ),
    );
  }
}

class _NextStepCard extends StatelessWidget {
  const _NextStepCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Your next step',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Decide the one problem your app solves. Then replace the Prototype screen with that core experience before adding extra features.',
          ),
        ],
      ),
    );
  }
}

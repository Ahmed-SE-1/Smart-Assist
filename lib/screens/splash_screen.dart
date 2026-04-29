import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19), // Dark background from UI
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Spacer(),
            // Logo Stack
            Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  Icons.home_outlined,
                  size: 120,
                  color: Theme.of(context).colorScheme.primary,
                ),
                Column(
                  children: [
                    Icon(
                      Icons.wifi,
                      size: 30,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 5),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.directions_walk,
                        size: 24,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ],
            ).animate().fade(duration: 500.ms).scale(delay: 200.ms),
            const SizedBox(height: 20),
            Text(
              'SMART HOME',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
              ),
            ).animate().fade(delay: 500.ms).slideY(),
            Text(
              'ASSIST',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Colors.white70,
                letterSpacing: 2,
              ),
            ).animate().fade(delay: 600.ms).slideY(),
            const Spacer(),
            const Text(
              'Loading...',
              style: TextStyle(color: Colors.white54, fontSize: 16),
            ).animate().fade(delay: 800.ms),
            const SizedBox(height: 20),
            const CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white24),
            ).animate().fade(delay: 800.ms),
            const SizedBox(height: 50),
          ],
        ),
      ),
    );
  }
}

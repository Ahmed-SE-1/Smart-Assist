import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/auth_provider.dart';

/// A transitional screen shown immediately after a new user logs in for the very first time.
/// It simulates discovering and connecting to the physical Smart Home Hub (e.g. Raspberry Pi) on the local network.
class HubConnectionScreen extends ConsumerStatefulWidget {
  const HubConnectionScreen({super.key});

  @override
  ConsumerState<HubConnectionScreen> createState() => _HubConnectionScreenState();
}

class _HubConnectionScreenState extends ConsumerState<HubConnectionScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startSimulation();
    });
  }

  /// Triggers a fake 2-second delay to simulate network discovery,
  /// then updates the `authProvider` state to [isHubConnected = true], which automatically redirects to the Dashboard.
  Future<void> _startSimulation() async {
    await ref.read(authProvider.notifier).simulateHubConnection();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 24),
            Text('Connecting to Smart Hub...'),
          ],
        ),
      ),
    );
  }
}

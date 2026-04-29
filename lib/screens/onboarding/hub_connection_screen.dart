import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers/auth_provider.dart';

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

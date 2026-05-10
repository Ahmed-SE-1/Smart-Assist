import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../models/user.dart';

class RoleSelectionScreen extends StatelessWidget {
  const RoleSelectionScreen({super.key}); // Error fix: Constructor add karein

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center( // Error fix: Center use karein taake alignment sahi ho
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
                "Select Your Role",
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)
            ),
            const SizedBox(height: 40),
            _roleCard(context, "House Owner", Icons.admin_panel_settings, UserRole.owner),
            const SizedBox(height: 20),
            _roleCard(context, "House Member", Icons.person_add, UserRole.member),
          ],
        ),
      ),
    );
  }

  // Widget function ko method ke taur par define karein
  Widget _roleCard(BuildContext context, String title, IconData icon, UserRole role) {
    return GestureDetector(
      onTap: () {
        // 'extra' ke zariye hum role object bhej rahe hain Signup screen ko
        context.push('/register', extra: role);
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.blue.shade50,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: Colors.blue),
        ),
        child: Row(
          children: [
            Icon(icon, size: 40, color: Colors.blue),
            const SizedBox(width: 20),
            Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
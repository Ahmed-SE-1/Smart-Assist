import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../providers/auth_provider.dart';
import '../../providers/user_provider.dart';
import '../../providers/accessibility_provider.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  Future<void> _editProfileDialog() async {
    final user = ref.read(userProvider);
    if (user == null) return;

    final nameController = TextEditingController(text: user.name);
    String? currentAvatarUrl = user.avatarUrl;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Edit Profile'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: () async {
                  final picker = ImagePicker();
                  final pickedFile = await picker.pickImage(source: ImageSource.gallery);
                  if (pickedFile != null) {
                    setDialogState(() {
                      currentAvatarUrl = pickedFile.path;
                    });
                  }
                },
                child: CircleAvatar(
                  radius: 40,
                  backgroundColor: Colors.grey.shade200,
                  backgroundImage: _getAvatarImage(currentAvatarUrl),
                  child: currentAvatarUrl == null || currentAvatarUrl!.isEmpty
                      ? const Icon(Icons.camera_alt, color: Colors.grey)
                      : null,
                ),
              ),
              const SizedBox(height: 8),
              const Text('Tap to change photo', style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 16),
              TextFormField(
                initialValue: user.email,
                decoration: const InputDecoration(labelText: 'Email', enabled: false),
                style: const TextStyle(color: Colors.grey),
                enabled: false,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                ref.read(userProvider.notifier).updateUser(
                  name: nameController.text,
                  email: user.email, // email remains unchanged
                  avatarUrl: currentAvatarUrl,
                );
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Profile updated'), backgroundColor: Colors.green),
                );
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  ImageProvider _getAvatarImage(String? avatarUrl) {
    if (avatarUrl == null || avatarUrl.isEmpty) {
      return const NetworkImage('https://i.pravatar.cc/150?img=11');
    } else if (avatarUrl.startsWith('http')) {
      return NetworkImage(avatarUrl);
    } else {
      return FileImage(File(avatarUrl));
    }
  }

  bool _voiceFeedbackEnabled = false;
  bool _alertSoundEnabled = false;

  @override
  void initState() {
    super.initState();
    _loadAccessibilitySettings();
  }

  Future<void> _loadAccessibilitySettings() async {
    // Assuming SharedPreferences is used directly here or via a service
    // Defaulting to simple local state for now
    // A proper implementation would load from local_storage_service
  }

  Future<void> _showAccessibilityDialog() async {
    await showDialog(
      context: context,
      builder: (context) => Consumer( // Consumer add kiya taake global state read ho
          builder: (context, ref, child) {
            // Riverpod se current status uthaya
            final isVoiceEnabled = ref.watch(voiceFeedbackProvider);

            return AlertDialog(
              title: Semantics(
                header: true,
                child: Text('Accessibility Settings'),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    label: 'Toggle Voice Feedback',
                    child: SwitchListTile(
                      title: const Text('Voice Feedback'),
                      subtitle: const Text('App will speak when actions are performed'),
                      value: isVoiceEnabled,
                      onChanged: (val) {
                        // Provider update kiya
                        ref.read(voiceFeedbackProvider.notifier).state = val;

                        // Agar ON kiya hai toh foran demo aawaz sunao
                        if (val) {
                          ref.read(ttsServiceProvider).speak("Voice feedback is now enabled");
                        }
                      },
                      activeColor: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  // Alert sound wali tile waise hi rahegi
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ],
            );
          }
      ),
    );
  }

  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Help & Support'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('SmartAssist Help Center\n', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('• How to add a room: Go to Home -> Tap Add -> Provide name.'),
            Text('• How to use Voice: Go to Control -> Tap Mic -> Speak.'),
            Text('• Contact us: support@smartassist.com'),
            Text('• Version: 1.0.0'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(userProvider);
    
    if (user == null) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FC),
      appBar: AppBar(
        title: const Text('Profile & Settings'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
        child: Column(
          children: [
            // Profile Card
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF6C5CE7), Color(0xFF8E84F3)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF6C5CE7).withOpacity(0.3),
                    blurRadius: 15,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                    child: CircleAvatar(
                      radius: 32,
                      backgroundImage: _getAvatarImage(user.avatarUrl),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user.name,
                          style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          user.email,
                          style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),

            // Settings List
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                children: [
                  _buildListTile(Icons.person_outline, 'Profile Information', onTap: _editProfileDialog),
                  _buildDivider(),
                  _buildListTile(Icons.accessibility_new, 'Accessibility Settings', onTap: _showAccessibilityDialog),
                  _buildDivider(),
                  _buildListTile(Icons.auto_awesome_mosaic_outlined, 'Automation Rules', onTap: () => context.push('/automation')),
                  _buildDivider(),
                  _buildListTile(Icons.help_outline, 'Help & Support', onTap: _showHelpDialog),
                ],
              ),
            ),
            const SizedBox(height: 32),

            // Logout Button
            TextButton.icon(
              onPressed: () => ref.read(authProvider.notifier).logout(),
              icon: const Icon(Icons.logout, color: Colors.red),
              label: const Text('Logout', style: TextStyle(color: Colors.red, fontSize: 16, fontWeight: FontWeight.bold)),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 32),
                backgroundColor: Colors.red.withOpacity(0.1),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildListTile(IconData icon, String title, {VoidCallback? onTap}) {
    return Semantics(
      button: true, // TalkBack ko batayega ke ye button hai
      label: title, // TalkBack title parhega
      hint: 'Double tap to open', // TalkBack user ko hint dega
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFFF7F8FC),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: const Color(0xFF2D3436)),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF2D3436))),
        trailing: const Icon(Icons.chevron_right, color: Colors.grey),
        onTap: onTap,
        // Exclude semantics from inner widgets to avoid double reading
        // title aur trailing ko dubara parhne se rokne ke liye:
      ),
    );
  }

  Widget _buildDivider() {
    return Padding(
      padding: const EdgeInsets.only(left: 64.0, right: 16.0),
      child: Divider(color: Colors.grey.shade200, height: 1),
    );
  }
}

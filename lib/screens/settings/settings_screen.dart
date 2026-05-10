import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart'; // NEW: For Managing Members
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // NEW: For Clipboard Copy
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/user.dart'; // NEW: For UserRole
import '../../providers/accessibility_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/user_provider.dart';

/// The screen where users can manage their profile details, app preferences, and view support options.
/// Provides access to the Accessibility settings and Automation Rules.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {

  /// Opens a modal dialog allowing the user to update their Name and Profile Picture.
  Future<void> _editProfileDialog() async {
    final user = ref.read(userProvider);
    if (user == null) return;

    final nameController = TextEditingController(text: user.name);
    String? currentAvatarUrl = user.avatarUrl;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: const Text('Edit Profile', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
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
                child: Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    CircleAvatar(
                      radius: 48,
                      backgroundColor: Colors.grey.shade200,
                      backgroundImage: _getAvatarImage(currentAvatarUrl),
                    ),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: const BoxDecoration(color: Color(0xFF6C5CE7), shape: BoxShape.circle),
                      child: const Icon(Icons.camera_alt, color: Colors.white, size: 20),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: 'Full Name',
                  filled: true,
                  fillColor: Colors.grey.shade100,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  prefixIcon: const Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                initialValue: user.email,
                decoration: InputDecoration(
                  labelText: 'Email Address',
                  filled: true,
                  fillColor: Colors.grey.shade100,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  prefixIcon: const Icon(Icons.email_outlined),
                ),
                style: const TextStyle(color: Colors.grey),
                enabled: false,
              ),
            ],
          ),
          actionsPadding: const EdgeInsets.all(24),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel', style: TextStyle(color: Colors.grey.shade600)),
            ),
            ElevatedButton(
              onPressed: () {
                ref.read(userProvider.notifier).updateUser(
                  name: nameController.text,
                  email: user.email,
                  avatarUrl: currentAvatarUrl,
                );
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Profile updated'), backgroundColor: Colors.green),
                );
              },
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Save Changes'),
            ),
          ],
        ),
      ),
    );
  }

  /// Determines how to render the user's avatar.
  ImageProvider _getAvatarImage(String? avatarUrl) {
    if (avatarUrl == null || avatarUrl.isEmpty) {
      return const NetworkImage('https://i.pravatar.cc/150?img=11');
    } else if (avatarUrl.startsWith('http')) {
      return NetworkImage(avatarUrl);
    } else {
      return FileImage(File(avatarUrl));
    }
  }

  /// Displays the Accessibility settings modal
  Future<void> _showAccessibilityDialog() async {
    await showDialog(
      context: context,
      builder: (context) => Consumer(
          builder: (context, ref, child) {
            final isVoiceEnabled = ref.watch(voiceFeedbackProvider);
            final isTextEnabled = ref.watch(showTextFeedbackProvider);

            return AlertDialog(
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              title: Semantics(
                header: true,
                child: const Text('Accessibility', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    label: 'Toggle Voice Feedback',
                    child: Container(
                      decoration: BoxDecoration(color: Colors.grey.shade50, borderRadius: BorderRadius.circular(16)),
                      child: SwitchListTile(
                        title: const Text('Voice Feedback', style: TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: const Text('App speaks actions aloud', style: TextStyle(fontSize: 12)),
                        value: isVoiceEnabled,
                        onChanged: (val) {
                          ref.read(voiceFeedbackProvider.notifier).toggle(val);
                          if (val) ref.read(ttsServiceProvider).speak("Voice feedback is now enabled");
                        },
                        activeColor: Theme.of(context).colorScheme.primary,
                        secondary: const Icon(Icons.record_voice_over),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Semantics(
                    label: 'Toggle Visual Text Feedback',
                    child: Container(
                      decoration: BoxDecoration(color: Colors.grey.shade50, borderRadius: BorderRadius.circular(16)),
                      child: SwitchListTile(
                        title: const Text('Visual Text', style: TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: const Text('Display commands on screen', style: TextStyle(fontSize: 12)),
                        value: isTextEnabled,
                        onChanged: (val) {
                          ref.read(showTextFeedbackProvider.notifier).toggle(val);
                        },
                        activeColor: Theme.of(context).colorScheme.primary,
                        secondary: const Icon(Icons.subtitles),
                      ),
                    ),
                  ),
                ],
              ),
              actionsPadding: const EdgeInsets.all(24),
              actions: [
                ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Done'),
                ),
              ],
            );
          }
      ),
    );
  }

  /// Displays the Join Code for the House Owner
  void _showJoinCodeDialog(String? joinCode) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('House Join Code', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22), textAlign: TextAlign.center),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.vpn_key_rounded, size: 64, color: Color(0xFF6C5CE7)),
            const SizedBox(height: 16),
            const Text(
              'Share this code with your family members so they can join your smart home.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, height: 1.5),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 32),
              decoration: BoxDecoration(
                color: const Color(0xFF6C5CE7).withOpacity(0.1),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF6C5CE7).withOpacity(0.5), width: 2),
              ),
              child: Text(
                joinCode ?? 'Error',
                style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Color(0xFF6C5CE7), letterSpacing: 8),
              ),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.all(24),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Close', style: TextStyle(color: Colors.grey.shade600)),
          ),
          ElevatedButton.icon(
            onPressed: () {
              if (joinCode != null) {
                Clipboard.setData(ClipboardData(text: joinCode));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Code copied to clipboard!'), backgroundColor: Colors.green),
                );
                Navigator.pop(context);
              }
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy Code'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }

  /// Displays the Member Management dialog for the House Owner
  void _showManageMembersDialog(String houseId, String ownerId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('Manage Members', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
        content: SizedBox(
          width: double.maxFinite,
          height: 350,
          child: StreamBuilder<QuerySnapshot>(
            // Querying users who belong to this house, but excluding the owner themselves
            stream: FirebaseFirestore.instance.collection('users').where('houseId', isEqualTo: houseId).snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                return const Center(child: Text('No members found.', style: TextStyle(color: Colors.grey)));
              }

              // Filter out the owner from the list
              final members = snapshot.data!.docs.where((doc) => doc.id != ownerId).toList();

              if (members.isEmpty) {
                return const Center(child: Text('No family members have joined yet.', style: TextStyle(color: Colors.grey)));
              }

              return ListView.separated(
                itemCount: members.length,
                separatorBuilder: (context, index) => Divider(color: Colors.grey.shade200),
                itemBuilder: (context, index) {
                  final data = members[index].data() as Map<String, dynamic>;
                  final docId = members[index].id;
                  final isApproved = data['isApproved'] ?? false;
                  final memberName = data['name'] ?? 'Unknown User';

                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: isApproved ? Colors.green.shade100 : Colors.orange.shade100,
                      child: Icon(
                        isApproved ? Icons.person : Icons.pending_actions,
                        color: isApproved ? Colors.green : Colors.orange,
                      ),
                    ),
                    title: Text(memberName, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(
                      isApproved ? 'Approved Member' : 'Pending Approval',
                      style: TextStyle(color: isApproved ? Colors.green : Colors.orange, fontSize: 12),
                    ),
                    trailing: Switch(
                      value: isApproved,
                      activeColor: Colors.green,
                      onChanged: (val) {
                        FirebaseFirestore.instance.collection('users').doc(docId).update({'isApproved': val});
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(val ? '$memberName Approved' : '$memberName Access Revoked'),
                            backgroundColor: val ? Colors.green : Colors.orange,
                          ),
                        );
                      },
                    ),
                  );
                },
              );
            },
          ),
        ),
        actionsPadding: const EdgeInsets.all(24),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('Help & Support', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: Colors.blue.shade50, borderRadius: BorderRadius.circular(16)),
              child: const Row(
                children: [
                  Icon(Icons.support_agent, color: Colors.blue, size: 32),
                  SizedBox(width: 16),
                  Expanded(child: Text('We are here to help you!', style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold))),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const Text('• Add a room: Go to Home -> Tap Add -> Provide name.'),
            const SizedBox(height: 8),
            const Text('• Voice Control: Go to Dashboard -> Tap Voice Assistant.'),
            const SizedBox(height: 8),
            const Text('• Automations: Add rules from the settings screen.'),
            const SizedBox(height: 24),
            const Center(child: Text('Version: 1.0.0', style: TextStyle(color: Colors.grey, fontSize: 12))),
          ],
        ),
        actionsPadding: const EdgeInsets.all(24),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
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
        title: const Text('Profile', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF2D3436))),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Modern Profile Card
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF6C5CE7), Color(0xFF8E84F3)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(color: const Color(0xFF6C5CE7).withOpacity(0.4), blurRadius: 20, offset: const Offset(0, 10)),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                    child: CircleAvatar(
                      radius: 36,
                      backgroundImage: _getAvatarImage(user.avatarUrl),
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user.name,
                          style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          user.email,
                          style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit, color: Colors.white),
                    onPressed: _editProfileDialog,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),

            // --- NEW: HOUSEHOLD MANAGEMENT (ONLY FOR OWNER) ---
            if (user.role == UserRole.owner) ...[
              const Text('HOUSEHOLD MANAGEMENT', style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 5))]),
                child: Column(
                  children: [
                    _buildListTile(Icons.vpn_key_outlined, 'House Join Code', onTap: () => _showJoinCodeDialog(user.joinCode)),
                    _buildDivider(),
                    _buildListTile(Icons.people_alt_outlined, 'Manage Members', onTap: () => _showManageMembersDialog(user.houseId ?? user.id, user.id)),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
            // --------------------------------------------------

            // Settings Group 1: Preferences
            const Text('PREFERENCES', style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 5))]),
              child: Column(
                children: [
                  _buildListTile(Icons.accessibility_new, 'Accessibility', onTap: _showAccessibilityDialog),
                  _buildDivider(),
                  _buildListTile(Icons.auto_awesome_mosaic_outlined, 'Automation Rules', onTap: () => context.push('/automation')),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Settings Group 2: Support
            const Text('SUPPORT', style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 5))]),
              child: Column(
                children: [
                  _buildListTile(Icons.help_outline, 'Help & Support', onTap: _showHelpDialog),
                  _buildDivider(),
                  _buildListTile(Icons.info_outline, 'About App', onTap: () {}),
                ],
              ),
            ),
            const SizedBox(height: 32),

            // Logout Button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => ref.read(authProvider.notifier).logout(),
                icon: const Icon(Icons.logout, color: Colors.red),
                label: const Text('Log Out', style: TextStyle(color: Colors.red, fontSize: 16, fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.withOpacity(0.1),
                  foregroundColor: Colors.red,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                ),
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  /// A helper method to build consistent, styling list items for the Settings menus.
  Widget _buildListTile(IconData icon, String title, {VoidCallback? onTap}) {
    return Semantics(
      button: true,
      label: title,
      hint: 'Double tap to open',
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: const Color(0xFFF7F8FC), borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: const Color(0xFF2D3436), size: 22),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF2D3436), fontSize: 16)),
        trailing: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(color: Colors.grey.shade100, shape: BoxShape.circle),
          child: const Icon(Icons.chevron_right, color: Colors.grey, size: 20),
        ),
        onTap: onTap,
      ),
    );
  }

  Widget _buildDivider() {
    return Padding(
      padding: const EdgeInsets.only(left: 68.0, right: 20.0),
      child: Divider(color: Colors.grey.shade100, height: 1),
    );
  }
}
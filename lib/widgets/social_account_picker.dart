import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

class SocialAccount {
  final String name;
  final String email;
  final String? avatarUrl;

  const SocialAccount({required this.name, required this.email, this.avatarUrl});
}

class SocialAccountPicker extends StatefulWidget {
  final String provider;
  final List<SocialAccount> accounts;

  const SocialAccountPicker({
    super.key,
    required this.provider,
    required this.accounts,
  });

  @override
  State<SocialAccountPicker> createState() => _SocialAccountPickerState();

  static Future<SocialAccount?> show(BuildContext context, String provider, {List<SocialAccount>? initialAccounts}) {
    final List<SocialAccount> mockAccounts = initialAccounts ?? [];

    return showModalBottomSheet<SocialAccount>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => SocialAccountPicker(provider: provider, accounts: mockAccounts),
    );
  }
}

class _SocialAccountPickerState extends State<SocialAccountPicker> {
  bool _isAddingAccount = false;
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),
          
          if (!_isAddingAccount) ...[
            _buildHeader(),
            const SizedBox(height: 24),
            _buildAccountList(),
            const Divider(),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              leading: const Icon(Icons.person_add_alt_outlined),
              title: const Text('Use another account', style: TextStyle(fontWeight: FontWeight.w500)),
              onTap: () => setState(() => _isAddingAccount = true),
            ),
          ] else ...[
            _buildAddAccountForm(),
          ],
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            children: [
              Icon(
                widget.provider == 'Google' ? Icons.g_mobiledata : Icons.apple,
                size: 32,
                color: widget.provider == 'Google' ? Colors.red : Colors.black,
              ),
              const SizedBox(width: 12),
              Text(
                'Choose an account',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            'to continue to SmartAssist',
            style: TextStyle(color: Colors.grey.shade600),
          ),
        ),
      ],
    ).animate().fadeIn();
  }

  Widget _buildAccountList() {
    return Flexible(
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: widget.accounts.length,
        itemBuilder: (context, index) {
          final account = widget.accounts[index];
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
            leading: CircleAvatar(
              backgroundColor: Colors.blue.shade100,
              backgroundImage: account.avatarUrl != null ? NetworkImage(account.avatarUrl!) : null,
              child: account.avatarUrl == null ? Text(account.name[0]) : null,
            ),
            title: Text(account.name, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(account.email),
            onTap: () => Navigator.pop(context, account),
          ).animate().fadeIn(delay: Duration(milliseconds: 50 * index)).slideX(begin: 0.1);
        },
      ),
    );
  }

  Widget _buildAddAccountForm() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: () => setState(() => _isAddingAccount = false),
                icon: const Icon(Icons.arrow_back),
              ),
              Text(
                'Add an account',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: 'Full Name',
              hintText: 'e.g. John Doe',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              prefixIcon: const Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _emailController,
            decoration: InputDecoration(
              labelText: 'Email Address',
              hintText: 'e.g. user@example.com',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              prefixIcon: const Icon(Icons.email_outlined),
            ),
            keyboardType: TextInputType.emailAddress,
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () {
              if (_nameController.text.isNotEmpty && _emailController.text.isNotEmpty) {
                Navigator.pop(context, SocialAccount(
                  name: _nameController.text,
                  email: _emailController.text,
                ));
              }
            },
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Continue', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 16),
        ],
      ),
    ).animate().fadeIn().slideY(begin: 0.2);
  }
}

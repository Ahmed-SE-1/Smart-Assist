// register_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/auth_provider.dart';
import '../../models/user.dart';

class RegisterScreen extends ConsumerStatefulWidget {
  final UserRole selectedRole;

  const RegisterScreen({super.key, required this.selectedRole});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();

  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  final _joinCodeController = TextEditingController(); // For Members
  final _houseNameController = TextEditingController(); // For Owners

  bool _obscurePassword = true;
  bool _obscureConfirm = true;

  Future<void> _register() async {
    if (_formKey.currentState!.validate()) {
      final success = await ref.read(authProvider.notifier).signup(
        _nameController.text.trim(),
        _emailController.text.trim(),
        _passwordController.text.trim(),
        widget.selectedRole,
        joinCode: widget.selectedRole == UserRole.member ? _joinCodeController.text.trim() : null,
        houseName: widget.selectedRole == UserRole.owner ? _houseNameController.text.trim() : null,
      );

      if (!mounted) return;

      final authState = ref.read(authProvider);

      if (!success && authState.error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(authState.error!), backgroundColor: Colors.red),
        );
      } else if (success) {
        context.go('/home');
      }
    }
  }

  Future<void> _handleGoogleSignIn() async {
    if (widget.selectedRole == UserRole.owner && _houseNameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a House Name first before continuing with Google.'), backgroundColor: Colors.orange),
      );
      return;
    }

    if (widget.selectedRole == UserRole.member && _joinCodeController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a Join Code first before continuing with Google.'), backgroundColor: Colors.orange),
      );
      return;
    }

    final success = await ref.read(authProvider.notifier).signUpWithGoogle(
      widget.selectedRole,
      houseName: widget.selectedRole == UserRole.owner ? _houseNameController.text.trim() : null,
      joinCode: widget.selectedRole == UserRole.member ? _joinCodeController.text.trim() : null,
    );

    if (!mounted) return;

    final authState = ref.read(authProvider);
    if (success) {
      context.go('/home');
    } else if (authState.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(authState.error!), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black),
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 16.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Create ${widget.selectedRole == UserRole.owner ? "Owner" : "Member"} Account',
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF2D3436),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 40),

                    if (widget.selectedRole == UserRole.owner) ...[
                      _buildTextField(
                        controller: _houseNameController,
                        hint: 'House Name / Number (e.g. Villa 42)',
                        icon: Icons.home_work_outlined,
                        validator: (val) => val != null && val.isEmpty ? 'House Name is required' : null,
                      ),
                      const SizedBox(height: 16),
                    ],

                    if (widget.selectedRole == UserRole.member) ...[
                      _buildTextField(
                        controller: _joinCodeController,
                        hint: 'Enter House Join Code (e.g. 123456)',
                        icon: Icons.vpn_key_outlined,
                        validator: (val) => val != null && val.length < 6 ? 'Enter a valid 6-digit code' : null,
                      ),
                      const SizedBox(height: 16),
                    ],

                    _buildTextField(
                      controller: _nameController,
                      hint: 'Full Name',
                      icon: Icons.person_outline,
                      validator: (val) => val != null && val.isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),

                    _buildTextField(
                      controller: _emailController,
                      hint: 'Email Address',
                      icon: Icons.email_outlined,
                      validator: (val) => val != null && !val.contains('@') ? 'Invalid email' : null,
                    ),
                    const SizedBox(height: 16),

                    _buildTextField(
                      controller: _passwordController,
                      hint: 'Password',
                      icon: Icons.lock_outline,
                      obscure: _obscurePassword,
                      onToggle: () => setState(() => _obscurePassword = !_obscurePassword),
                      validator: (val) => val != null && val.length < 6 ? 'Too short' : null,
                    ),
                    const SizedBox(height: 16),

                    _buildTextField(
                      controller: _confirmController,
                      hint: 'Confirm Password',
                      icon: Icons.lock_outline,
                      obscure: _obscureConfirm,
                      onToggle: () => setState(() => _obscureConfirm = !_obscureConfirm),
                      validator: (val) => val != _passwordController.text ? 'Passwords do not match' : null,
                    ),
                    const SizedBox(height: 32),

                    if (authState.isLoading)
                      const Center(child: CircularProgressIndicator())
                    else
                      ElevatedButton(
                        onPressed: _register,
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('Sign Up', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ),

                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(child: Divider(color: Colors.grey.shade300)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text('OR', style: TextStyle(color: Colors.grey.shade500, fontWeight: FontWeight.w500)),
                        ),
                        Expanded(child: Divider(color: Colors.grey.shade300)),
                      ],
                    ),
                    const SizedBox(height: 24),

                    OutlinedButton.icon(
                      onPressed: authState.isLoading ? null : _handleGoogleSignIn,
                      // --- FIXED: Using PNG instead of SVG ---
                      icon: Image.network(
                        'https://developers.google.com/identity/images/g-logo.png', // Official Google PNG Logo
                        height: 24,
                        errorBuilder: (context, error, stackTrace) => const Icon(Icons.add, size: 24, color: Colors.grey),
                      ),
                      label: const Text('Continue with Google', style: TextStyle(color: Colors.black87, fontSize: 16)),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        side: BorderSide(color: Colors.grey.shade300),
                      ),
                    ),

                    const SizedBox(height: 32),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text("Already have an account?", style: TextStyle(color: Colors.grey.shade600)),
                        TextButton(
                          onPressed: () => context.go('/login'),
                          child: Text(
                            'Login',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool obscure = false,
    VoidCallback? onToggle,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: Colors.grey),
        suffixIcon: onToggle != null ? IconButton(
          icon: Icon(
            obscure ? Icons.visibility_off : Icons.visibility,
            color: Colors.grey,
          ),
          onPressed: onToggle,
        ) : null,
        hintText: hint,
        filled: true,
        fillColor: const Color(0xFFF7F8FC),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      validator: validator,
    );
  }
}
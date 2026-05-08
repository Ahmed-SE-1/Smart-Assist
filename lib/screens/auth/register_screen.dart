import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/auth_provider.dart';

/// The screen where a new user can create a SmartAssist account via Email or Google.
class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  // A global key that uniquely identifies the Form widget and allows validation of the form.
  final _formKey = GlobalKey<FormState>();
  
  // Controllers to read the text input from the user.
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  
  // Toggles for password visibility.
  bool _obscurePassword = true;
  bool _obscureConfirm = true;

  /// Attempts to register a new user in Firebase.
  Future<void> _register() async {
    // 1. Validate that all fields meet requirements (length, email format, passwords match)
    if (_formKey.currentState!.validate()) {
      
      // 2. Call the authentication provider to attempt Firebase signup
      final success = await ref.read(authProvider.notifier).signup(
        _nameController.text,
        _emailController.text, 
        _passwordController.text
      );
      
      if (!mounted) return;
      
      // 3. Handle response: Show error if failed, or navigate to dashboard if successful
      final authState = ref.read(authProvider);
      if (!success && authState.error != null) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(authState.error!), backgroundColor: Colors.red),
          );
      } else if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Account created successfully!'), backgroundColor: Colors.green),
          );
          context.go('/home');
      }
    }
  }

  /// Initiates the Google Sign-In OAuth flow.
  Future<void> _handleGoogleSignIn() async {
    await ref.read(authProvider.notifier).signInWithGoogle();
    
    if (!mounted) return;

    final authState = ref.read(authProvider);
    if (authState.isAuthenticated) {
      context.go('/home');
    } else if (authState.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(authState.error!), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
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
                    // Main Welcome Header
                    Text(
                      'Create Account',
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF2D3436),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Sign up to get started',
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 16),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 40),
                    
                    // --- Full Name Input Field ---
                    _buildTextField(
                      controller: _nameController,
                      hint: 'Full Name',
                      icon: Icons.person_outline,
                      validator: (val) => val != null && val.isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    
                    // --- Email Input Field ---
                    _buildTextField(
                      controller: _emailController,
                      hint: 'Email Address',
                      icon: Icons.email_outlined,
                      validator: (val) => val != null && !val.contains('@') ? 'Invalid email' : null,
                    ),
                    const SizedBox(height: 16),
                    
                    // --- Password Input Field ---
                    _buildTextField(
                      controller: _passwordController,
                      hint: 'Password',
                      icon: Icons.lock_outline,
                      obscure: _obscurePassword,
                      onToggle: () => setState(() => _obscurePassword = !_obscurePassword),
                      validator: (val) => val != null && val.length < 6 ? 'Too short' : null,
                    ),
                    const SizedBox(height: 16),
                    
                    // --- Confirm Password Input Field ---
                    _buildTextField(
                      controller: _confirmController,
                      hint: 'Confirm Password',
                      icon: Icons.lock_outline,
                      obscure: _obscureConfirm,
                      onToggle: () => setState(() => _obscureConfirm = !_obscureConfirm),
                      // Validates that both passwords match exactly
                      validator: (val) => val != _passwordController.text ? 'Passwords do not match' : null,
                    ),
                    const SizedBox(height: 32),
                    
                    // --- Register Button / Loading Spinner ---
                    if (ref.watch(authProvider).isLoading)
                      const Center(child: CircularProgressIndicator())
                    else
                      ElevatedButton(
                        onPressed: _register,
                        child: const Text('Sign Up', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                    const SizedBox(height: 32),
                    
                    // --- Separator ---
                    Row(
                      children: [
                        Expanded(child: Divider(color: Colors.grey.shade300)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text('Or continue with', style: TextStyle(color: Colors.grey.shade600)),
                        ),
                        Expanded(child: Divider(color: Colors.grey.shade300)),
                      ],
                    ),
                    const SizedBox(height: 24),
                    
                    // --- Google Auth Button ---
                    OutlinedButton.icon(
                      onPressed: ref.watch(authProvider).isLoading ? null : () => _handleGoogleSignIn(),
                      icon: const Icon(Icons.g_mobiledata, size: 28, color: Colors.red),
                      label: const Text('Continue with Google', style: TextStyle(color: Colors.black87)),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        side: BorderSide(color: Colors.grey.shade300),
                        minimumSize: const Size(double.infinity, 56), // full width
                      ),
                    ),
                    const SizedBox(height: 32),
                    
                    // --- Navigate to Login ---
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text("Already have an account?", style: TextStyle(color: Colors.grey.shade600)),
                        TextButton(
                          onPressed: () => context.pop(),
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

  /// A helper widget to reduce boilerplate code for creating TextFields.
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

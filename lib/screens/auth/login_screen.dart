import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/auth_provider.dart';

/// The screen where users can authenticate via Email/Password or Google Sign-In.
/// Uses a [ConsumerStatefulWidget] so it can read from and write to Riverpod providers.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  // A global key that uniquely identifies the Form widget and allows validation of the form.
  final _formKey = GlobalKey<FormState>();
  
  // Controllers to read the text input for Email and Password fields.
  final _emailController = TextEditingController(text: 'demo@example.com');
  final _passwordController = TextEditingController(text: 'password123');
  
  // Controls the visibility of the password characters.
  bool _obscurePassword = true;

  /// Attempts to log the user in using the provided email and password.
  Future<void> _login() async {
    // 1. Check if the inputs pass the validation rules defined in the TextFormFields
    if (_formKey.currentState!.validate()) {
      
      // 2. Call the authentication provider to attempt Firebase login
      final success = await ref.read(authProvider.notifier).login(
            _emailController.text,
            _passwordController.text,
          );
          
      // 3. Ensure the widget is still in the tree before updating UI
      if (!mounted) return;

      // 4. Handle response: Show error if failed, or navigate to dashboard if successful
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

  /// Initiates the Google Sign-In OAuth flow.
  Future<void> _handleGoogleSignIn() async {
    // Call the Google Auth method in the provider
    await ref.read(authProvider.notifier).signInWithGoogle();
    
    if (!mounted) return;

    final authState = ref.read(authProvider);
    if (authState.isAuthenticated) {
      // If successful, navigate to the main dashboard
      context.go('/home');
    } else if (authState.error != null) {
      // Show snackbar if the user cancels or an error occurs
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(authState.error!), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch the authProvider to react to loading states (e.g. showing a spinner while logging in)
    final authState = ref.watch(authProvider);

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 24.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 40),
                    // Main Welcome Header
                    Text(
                      'Welcome Back!',
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF2D3436),
                          ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Login to your account',
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 16),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 50),
                    
                    // --- Email Input Field ---
                    TextFormField(
                      controller: _emailController,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.email_outlined, color: Colors.grey),
                        hintText: 'Email Address',
                        filled: true,
                        fillColor: const Color(0xFFF7F8FC),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      // Validates that field isn't empty and contains an '@'
                      validator: (val) => val == null || val.isEmpty ? 'Required' : (!val.contains('@') ? 'Invalid email' : null),
                    ),
                    const SizedBox(height: 16),
                    
                    // --- Password Input Field ---
                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.lock_outline, color: Colors.grey),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscurePassword ? Icons.visibility_off : Icons.visibility,
                            color: Colors.grey,
                          ),
                          // Toggles visibility of the password
                          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                        ),
                        hintText: 'Password',
                        filled: true,
                        fillColor: const Color(0xFFF7F8FC),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      validator: (val) => val == null || val.isEmpty ? 'Required' : (val.length < 6 ? 'Too short' : null),
                    ),
                    const SizedBox(height: 8),
                    
                    // --- Forgot Password Button ---
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () async {
                          if (_emailController.text.isEmpty || !_emailController.text.contains('@')) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Please enter a valid email address first.')),
                            );
                            return;
                          }
                          // Request Firebase to send a reset link to the provided email
                          final success = await ref.read(authProvider.notifier).resetPassword(_emailController.text);
                          if (mounted && success) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Password reset email sent!'), backgroundColor: Colors.green),
                            );
                          } else if (mounted) {
                            final error = ref.read(authProvider).error;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(error ?? 'Failed to send reset email'), backgroundColor: Colors.red),
                            );
                          }
                        },
                        child: Text(
                          'Forgot Password?',
                          style: TextStyle(color: Theme.of(context).colorScheme.primary),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    
                    // --- Login Button / Loading Spinner ---
                    if (authState.isLoading)
                      const Center(child: CircularProgressIndicator())
                    else
                      ElevatedButton(
                        onPressed: _login,
                        child: const Text('Login', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                    const SizedBox(height: 40),
                    
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
                    const SizedBox(height: 40),
                    
                    // --- Navigate to Sign Up ---
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text("Don't have an account?", style: TextStyle(color: Colors.grey.shade600)),
                        TextButton(
                          onPressed: () => context.push('/register'),
                          child: Text(
                            'Sign Up',
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
}

// login_screen.dart
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/auth_provider.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;

  Future<void> _login() async {
    if (_formKey.currentState!.validate()) {
      final success = await ref.read(authProvider.notifier).login(
        _emailController.text.trim(),
        _passwordController.text.trim(),
      );

      if (!mounted) return;

      final authState = ref.read(authProvider);

      if (success) {
        context.go('/home');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    authState.error ?? 'Login failed. Please check your credentials.',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  // Google Sign-In Handler
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
    final authState = ref.watch(authProvider);

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.home_max_outlined, size: 80, color: Colors.blue),
                    const SizedBox(height: 24),
                    Text(
                      'Welcome Back!',
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF2D3436),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 40),

                    TextFormField(
                      controller: _emailController,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.email_outlined),
                        hintText: 'Email Address',
                        filled: true,
                        fillColor: const Color(0xFFF7F8FC),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      ),
                      validator: (val) => val == null || !val.contains('@') ? 'Invalid email' : null,
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                        ),
                        hintText: 'Password',
                        filled: true,
                        fillColor: const Color(0xFFF7F8FC),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 24),

                    if (authState.isLoading)
                      const Center(child: CircularProgressIndicator())
                    else
                      ElevatedButton(
                        onPressed: _login,
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('Login', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
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
                        // Optional: Error builder to show something if network fails
                        errorBuilder: (context, error, stackTrace) => const Icon(Icons.login, size: 24, color: Colors.grey),
                      ),
                      label: const Text('Continue with Google', style: TextStyle(color: Colors.black87, fontSize: 16)),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        side: BorderSide(color: Colors.grey.shade300),
                      ),
                    ),

                    const SizedBox(height: 40),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text("Don't have an account?", style: TextStyle(color: Colors.grey.shade600)),
                        TextButton(
                          onPressed: () => context.push('/role-selection'),
                          child: const Text('Sign Up', style: TextStyle(fontWeight: FontWeight.bold)),
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
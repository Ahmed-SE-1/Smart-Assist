import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router.dart';
import 'core/theme.dart';
import 'firebase_options.dart';
import 'providers/theme_provider.dart';

/// The main entry point for the SmartAssist application.
void main() async {
  // Ensures that the Flutter engine is properly initialized before running async code
  // This is required before calling Firebase.initializeApp() or using SharedPreferences.
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase using the auto-generated configuration file.
  // This connects our app to Firebase Auth, Firestore, etc.
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Wrap the entire app inside a ProviderScope.
  // This is strictly required by Flutter Riverpod to store and manage global app state.
  runApp(const ProviderScope(child: SmartAssistApp()));
}

/// The root widget of the application.
/// It listens to the global theme state and router configuration.
class SmartAssistApp extends ConsumerWidget {
  const SmartAssistApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch the themeProvider to rebuild the app when the user changes theme settings
    // (e.g., toggles dark mode, high contrast, or text size)
    final themeSettings = ref.watch(themeProvider);
    
    // Watch the routerProvider which handles all navigation and authentication redirects
    final router = ref.watch(routerProvider);

    // Using MaterialApp.router instead of standard MaterialApp to support GoRouter (declarative routing)
    return MaterialApp.router(
      title: 'SmartAssist',
      debugShowCheckedModeBanner: false, // Hides the red "DEBUG" banner in the top right corner
      
      // Inject dynamically generated Light and Dark themes based on user accessibility preferences
      theme: AppTheme.lightTheme(themeSettings.isHighContrast, themeSettings.fontSizeFactor),
      darkTheme: AppTheme.darkTheme(themeSettings.isHighContrast, themeSettings.fontSizeFactor),
      
      // Force the app to use Dark/Light mode based on the user's saved preference
      themeMode: themeSettings.isDarkMode ? ThemeMode.dark : ThemeMode.light,
      
      // Inject our GoRouter configuration which controls URL paths and screen transitions
      routerConfig: router,
    );
  }
}

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme.dart';
import 'core/router.dart';
import 'providers/theme_provider.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  runApp(const ProviderScope(child: SmartAssistApp()));
}

class SmartAssistApp extends ConsumerWidget {
  const SmartAssistApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeSettings = ref.watch(themeProvider);
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'SmartAssist',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme(themeSettings.isHighContrast, themeSettings.fontSizeFactor),
      darkTheme: AppTheme.darkTheme(themeSettings.isHighContrast, themeSettings.fontSizeFactor),
      themeMode: themeSettings.isDarkMode ? ThemeMode.dark : ThemeMode.light,
      routerConfig: router,
    );
  }
}

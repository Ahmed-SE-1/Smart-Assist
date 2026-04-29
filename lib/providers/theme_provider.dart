import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeSettings {
  final bool isDarkMode;
  final bool isHighContrast;
  final double fontSizeFactor;

  const ThemeSettings({
    required this.isDarkMode,
    required this.isHighContrast,
    required this.fontSizeFactor,
  });

  ThemeSettings copyWith({
    bool? isDarkMode,
    bool? isHighContrast,
    double? fontSizeFactor,
  }) {
    return ThemeSettings(
      isDarkMode: isDarkMode ?? this.isDarkMode,
      isHighContrast: isHighContrast ?? this.isHighContrast,
      fontSizeFactor: fontSizeFactor ?? this.fontSizeFactor,
    );
  }
}

class ThemeNotifier extends Notifier<ThemeSettings> {
  @override
  ThemeSettings build() {
    Future.microtask(_loadSettings);
    return const ThemeSettings(isDarkMode: false, isHighContrast: false, fontSizeFactor: 1.0);
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    state = ThemeSettings(
      isDarkMode: prefs.getBool('isDarkMode') ?? false,
      isHighContrast: prefs.getBool('isHighContrast') ?? false,
      fontSizeFactor: prefs.getDouble('fontSizeFactor') ?? 1.0,
    );
  }

  Future<void> toggleDarkMode() async {
    final prefs = await SharedPreferences.getInstance();
    final newValue = !state.isDarkMode;
    await prefs.setBool('isDarkMode', newValue);
    state = state.copyWith(isDarkMode: newValue);
  }

  Future<void> toggleHighContrast() async {
    final prefs = await SharedPreferences.getInstance();
    final newValue = !state.isHighContrast;
    await prefs.setBool('isHighContrast', newValue);
    state = state.copyWith(isHighContrast: newValue);
  }

  Future<void> setFontSize(double size) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('fontSizeFactor', size);
    state = state.copyWith(fontSizeFactor: size);
  }
}

final themeProvider = NotifierProvider<ThemeNotifier, ThemeSettings>(ThemeNotifier.new);

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase;
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
    return const ThemeSettings(
      isDarkMode: false,
      isHighContrast: false,
      fontSizeFactor: 1.0,
    );
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    state = ThemeSettings(
      isDarkMode: prefs.getBool('isDarkMode') ?? false,
      isHighContrast: prefs.getBool('isHighContrast') ?? false,
      fontSizeFactor: prefs.getDouble('fontSizeFactor') ?? 1.0,
    );

    // Sync from Firestore if user is authenticated
    final uid = firebase.FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      try {
        final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
        if (doc.exists) {
          final data = doc.data();
          if (data != null) {
            bool changed = false;
            var isDark = state.isDarkMode;
            var isHigh = state.isHighContrast;
            var fontFactor = state.fontSizeFactor;

            if (data['isDarkMode'] is bool && data['isDarkMode'] != isDark) {
              isDark = data['isDarkMode'] as bool;
              await prefs.setBool('isDarkMode', isDark);
              changed = true;
            }
            if (data['isHighContrast'] is bool && data['isHighContrast'] != isHigh) {
              isHigh = data['isHighContrast'] as bool;
              await prefs.setBool('isHighContrast', isHigh);
              changed = true;
            }
            if (data['fontSizeFactor'] is num && (data['fontSizeFactor'] as num).toDouble() != fontFactor) {
              fontFactor = (data['fontSizeFactor'] as num).toDouble();
              await prefs.setDouble('fontSizeFactor', fontFactor);
              changed = true;
            }
            if (changed) {
              state = ThemeSettings(
                isDarkMode: isDark,
                isHighContrast: isHigh,
                fontSizeFactor: fontFactor,
              );
            }
          }
        }
      } catch (_) {}
    }
  }

  void _saveToFirestore(String key, dynamic value) {
    final uid = firebase.FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .update({key: value})
          .catchError((_) {});
    }
  }

  Future<void> resetToDefaults() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('isDarkMode');
    await prefs.remove('isHighContrast');
    await prefs.remove('fontSizeFactor');
    state = const ThemeSettings(
      isDarkMode: false,
      isHighContrast: false,
      fontSizeFactor: 1.0,
    );
  }

  Future<void> syncFromUserDoc(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    var isDark = data['isDarkMode'] is bool ? data['isDarkMode'] as bool : false;
    var isHigh = data['isHighContrast'] is bool ? data['isHighContrast'] as bool : false;
    var fontFactor = data['fontSizeFactor'] is num ? (data['fontSizeFactor'] as num).toDouble() : 1.0;

    await prefs.setBool('isDarkMode', isDark);
    await prefs.setBool('isHighContrast', isHigh);
    await prefs.setDouble('fontSizeFactor', fontFactor);

    state = ThemeSettings(
      isDarkMode: isDark,
      isHighContrast: isHigh,
      fontSizeFactor: fontFactor,
    );
  }

  Future<void> toggleDarkMode() async {
    final prefs = await SharedPreferences.getInstance();
    final newValue = !state.isDarkMode;
    await prefs.setBool('isDarkMode', newValue);
    state = state.copyWith(isDarkMode: newValue);
    _saveToFirestore('isDarkMode', newValue);
  }

  Future<void> toggleHighContrast() async {
    final prefs = await SharedPreferences.getInstance();
    final newValue = !state.isHighContrast;
    await prefs.setBool('isHighContrast', newValue);
    state = state.copyWith(isHighContrast: newValue);
    _saveToFirestore('isHighContrast', newValue);
  }

  Future<void> setFontSize(double size) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('fontSizeFactor', size);
    state = state.copyWith(fontSizeFactor: size);
    _saveToFirestore('fontSizeFactor', size);
  }
}

final themeProvider = NotifierProvider<ThemeNotifier, ThemeSettings>(
  ThemeNotifier.new,
);

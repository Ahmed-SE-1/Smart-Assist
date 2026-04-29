import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // Brand colors from UI mockup
  static const Color primaryColor = Color(0xFF6C5CE7); // Deep Purple
  static const Color accentColor = Color(0xFF00E676); // Bright Green
  static const Color backgroundColorLight = Color(0xFFF7F8FC);
  static const Color backgroundColorDark = Color(0xFF0B0F19);
  static const Color cardColorLight = Colors.white;
  static const Color cardColorDark = Color(0xFF151A27);

  static ThemeData lightTheme(bool isHighContrast, double fontSizeFactor) {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryColor,
        brightness: Brightness.light,
        surface: backgroundColorLight,
        primary: isHighContrast ? Colors.deepPurple.shade900 : primaryColor,
        secondary: accentColor,
      ),
      scaffoldBackgroundColor: backgroundColorLight,
      cardTheme: CardTheme(
        color: cardColorLight,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(vertical: 16),
        )
      ),
      textTheme: GoogleFonts.poppinsTextTheme(ThemeData.light().textTheme).apply(
        fontSizeFactor: fontSizeFactor,
        bodyColor: isHighContrast ? Colors.black : const Color(0xFF2D3436),
        displayColor: isHighContrast ? Colors.black : const Color(0xFF2D3436),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: backgroundColorLight,
        elevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: Color(0xFF2D3436)),
        titleTextStyle: GoogleFonts.poppins(
          color: const Color(0xFF2D3436),
          fontSize: 18 * fontSizeFactor,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  static ThemeData darkTheme(bool isHighContrast, double fontSizeFactor) {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryColor,
        brightness: Brightness.dark,
        surface: backgroundColorDark,
        primary: isHighContrast ? Colors.yellow : primaryColor,
        secondary: accentColor,
      ),
      scaffoldBackgroundColor: backgroundColorDark,
      cardTheme: CardTheme(
        color: cardColorDark,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(vertical: 16),
        )
      ),
      textTheme: GoogleFonts.poppinsTextTheme(ThemeData.dark().textTheme).apply(
        fontSizeFactor: fontSizeFactor,
        bodyColor: isHighContrast ? Colors.white : Colors.white70,
        displayColor: isHighContrast ? Colors.white : Colors.white,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: backgroundColorDark,
        elevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.white),
        titleTextStyle: GoogleFonts.poppins(
          color: Colors.white,
          fontSize: 18 * fontSizeFactor,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

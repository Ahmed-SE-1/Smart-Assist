import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';

/// A robust wrapper around `SharedPreferences` for local data persistence.
/// Handles caching user data, authentication state, and onboarding progress.
class LocalStorageService {
  // Constant keys used to read/write from the device's persistent storage
  static const String _userKey = 'user_data';
  static const String _usersDbKey = 'users_db';
  static const String _isLoggedInKey = 'isLoggedIn';
  static const String _hasSeenOnboardingKey = 'hasSeenOnboarding';

  // Keys for hardware setup and accessibility options
  static const String _isFirstTimeKey = 'isFirstTime';
  static const String _hubConnectedKey = 'hubConnected';
  static const String _hubIdKey = 'hubId';
  static const String _screenReaderKey = 'screenReaderEnabled';
  static const String _voiceFeedbackKey = 'voiceFeedbackEnabled';
  static const String _visualAlertsKey = 'visualAlertsEnabled';

  /// Saves the current user's profile to local storage.
  /// Also updates a mock local "Database" of all users who have ever logged in.
  Future<void> saveUser(User user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, user.toJson());

    final usersDb = await getUsersDb();
    usersDb[user.email] = user.toMap();
    await prefs.setString(_usersDbKey, json.encode(usersDb));
  }

  /// Retrieves the mock local database of all registered users.
  Future<Map<String, dynamic>> getUsersDb() async {
    final prefs = await SharedPreferences.getInstance();
    final dbStr = prefs.getString(_usersDbKey);
    if (dbStr != null) {
      return json.decode(dbStr);
    }
    return {};
  }

  /// Mocks a backend by saving email/password credentials locally.
  Future<void> saveCredentials(String email, String password) async {
    final prefs = await SharedPreferences.getInstance();
    final credsStr = prefs.getString('mock_creds') ?? '{}';
    final creds = json.decode(credsStr);
    creds[email] = password;
    await prefs.setString('mock_creds', json.encode(creds));
  }

  /// Verifies credentials against the mock local backend.
  Future<bool> verifyCredentials(String email, String password) async {
    final prefs = await SharedPreferences.getInstance();
    final credsStr = prefs.getString('mock_creds') ?? '{}';
    final creds = json.decode(credsStr);
    return creds[email] == password;
  }

  /// Fetches the currently active user profile from local storage.
  Future<User?> getUser() async {
    final prefs = await SharedPreferences.getInstance();
    final userStr = prefs.getString(_userKey);
    if (userStr != null) {
      return User.fromJson(userStr);
    }
    return null;
  }

  /// Finds a specific user by email in the mock local database.
  Future<User?> getUserByEmail(String email) async {
    final db = await getUsersDb();
    if (db.containsKey(email)) {
      return User.fromMap(db[email]);
    }
    return null;
  }

  /// Returns a list of all users stored on this device.
  Future<List<User>> getAllUsers() async {
    final db = await getUsersDb();
    return db.values.map((map) => User.fromMap(map)).toList();
  }

  /// Wipes the current user data from memory (called during Logout).
  Future<void> clearUser() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_userKey);
    await prefs.setBool(_isLoggedInKey, false);
  }

  /// Flags whether a user session is currently active.
  Future<void> setLoggedIn(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_isLoggedInKey, value);
  }

  Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_isLoggedInKey) ?? false;
  }

  /// Flags whether the user has swiped through the introductory welcome screens.
  Future<void> setHasSeenOnboarding(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hasSeenOnboardingKey, value);
  }

  Future<bool> hasSeenOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_hasSeenOnboardingKey) ?? false;
  }

  // --- HARDWARE & HUB SETUP --- //

  /// Checks if this is the very first time the app is run to trigger hardware setup.
  Future<bool> isFirstTime() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_isFirstTimeKey) ?? true;
  }

  Future<void> setFirstTime(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_isFirstTimeKey, value);
  }

  /// Checks if the mock Raspberry Pi Hub has been linked.
  Future<bool> isHubConnected() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_hubConnectedKey) ?? false;
  }

  Future<void> setHubConnected(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hubConnectedKey, value);
  }

  Future<String?> getHubId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_hubIdKey);
  }

  Future<void> setHubId(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_hubIdKey, value);
  }

  // --- ACCESSIBILITY SETTINGS --- //

  /// Saves user preferences for Accessibility features (TTS, High Contrast, etc.)
  Future<void> saveAccessibilitySettings({
    required bool screenReader,
    required bool voiceFeedback,
    required bool visualAlerts,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_screenReaderKey, screenReader);
    await prefs.setBool(_voiceFeedbackKey, voiceFeedback);
    await prefs.setBool(_visualAlertsKey, visualAlerts);
  }

  Future<Map<String, bool>> getAccessibilitySettings() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'screenReader': prefs.getBool(_screenReaderKey) ?? false,
      'voiceFeedback': prefs.getBool(_voiceFeedbackKey) ?? false,
      'visualAlerts': prefs.getBool(_visualAlertsKey) ?? false,
    };
  }
}

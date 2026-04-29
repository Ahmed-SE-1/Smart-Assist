import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';

class LocalStorageService {
  static const String _userKey = 'user_data';
  static const String _usersDbKey = 'users_db';
  static const String _isLoggedInKey = 'isLoggedIn';
  static const String _hasSeenOnboardingKey = 'hasSeenOnboarding';
  
  // Onboarding enhancements
  static const String _isFirstTimeKey = 'isFirstTime';
  static const String _hubConnectedKey = 'hubConnected';
  static const String _hubIdKey = 'hubId';
  static const String _screenReaderKey = 'screenReaderEnabled';
  static const String _voiceFeedbackKey = 'voiceFeedbackEnabled';
  static const String _visualAlertsKey = 'visualAlertsEnabled';

  Future<void> saveUser(User user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, user.toJson());
    
    final usersDb = await getUsersDb();
    usersDb[user.email] = user.toMap(); 
    await prefs.setString(_usersDbKey, json.encode(usersDb));
  }

  Future<Map<String, dynamic>> getUsersDb() async {
    final prefs = await SharedPreferences.getInstance();
    final dbStr = prefs.getString(_usersDbKey);
    if (dbStr != null) {
      return json.decode(dbStr);
    }
    return {};
  }
  
  Future<void> saveCredentials(String email, String password) async {
      final prefs = await SharedPreferences.getInstance();
      final credsStr = prefs.getString('mock_creds') ?? '{}';
      final creds = json.decode(credsStr);
      creds[email] = password;
      await prefs.setString('mock_creds', json.encode(creds));
  }
  
  Future<bool> verifyCredentials(String email, String password) async {
      final prefs = await SharedPreferences.getInstance();
      final credsStr = prefs.getString('mock_creds') ?? '{}';
      final creds = json.decode(credsStr);
      return creds[email] == password;
  }

  Future<User?> getUser() async {
    final prefs = await SharedPreferences.getInstance();
    final userStr = prefs.getString(_userKey);
    if (userStr != null) {
      return User.fromJson(userStr);
    }
    return null;
  }
  
  Future<User?> getUserByEmail(String email) async {
     final db = await getUsersDb();
     if (db.containsKey(email)) {
         return User.fromMap(db[email]);
     }
     return null;
  }

  Future<List<User>> getAllUsers() async {
    final db = await getUsersDb();
    return db.values.map((map) => User.fromMap(map)).toList();
  }

  Future<void> clearUser() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_userKey);
    await prefs.setBool(_isLoggedInKey, false);
  }

  Future<void> setLoggedIn(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_isLoggedInKey, value);
  }

  Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_isLoggedInKey) ?? false;
  }

  Future<void> setHasSeenOnboarding(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hasSeenOnboardingKey, value);
  }

  Future<bool> hasSeenOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_hasSeenOnboardingKey) ?? false;
  }

  // Enhanced Onboarding Logic
  Future<bool> isFirstTime() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_isFirstTimeKey) ?? true;
  }

  Future<void> setFirstTime(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_isFirstTimeKey, value);
  }

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


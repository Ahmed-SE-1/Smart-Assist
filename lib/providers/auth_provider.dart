import 'package:firebase_auth/firebase_auth.dart' as firebase;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../models/user.dart';
import '../services/local_storage_service.dart';
import './automation_provider.dart';
import './smart_home_provider.dart';
import 'user_provider.dart';

/// Represents the current authentication and initialization state of the app.
/// This immutable class holds all the flags needed to determine which screen
/// to show the user (e.g., login, onboarding, dashboard, or hub connection).
class AuthState {
  final bool isAuthenticated; // Is the user successfully logged in?
  final String? error; // Any authentication errors (e.g., wrong password)
  final bool isLoading; // True when a network request is happening
  final bool isInitializing; // True when the app is first starting up
  final bool
  hasSeenOnboarding; // True if the user has completed the welcome slider
  final bool
  isFirstTime; // True if the user is logging in for the very first time
  final bool isHubConnected; // True if the mock Raspberry Pi Hub is connected

  const AuthState({
    this.isAuthenticated = false,
    this.error,
    this.isLoading = false,
    this.isInitializing = true,
    this.hasSeenOnboarding = false,
    this.isFirstTime = true,
    this.isHubConnected = false,
  });

  /// Creates a copy of the current state with specific fields updated.
  /// This is standard practice in immutable state management (like Riverpod).
  AuthState copyWith({
    bool? isAuthenticated,
    String? error,
    bool? isLoading,
    bool? isInitializing,
    bool? hasSeenOnboarding,
    bool? isFirstTime,
    bool? isHubConnected,
    bool clearError = false, // Special flag to wipe out previous errors
  }) {
    return AuthState(
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      error: clearError ? null : (error ?? this.error),
      isLoading: isLoading ?? this.isLoading,
      isInitializing: isInitializing ?? this.isInitializing,
      hasSeenOnboarding: hasSeenOnboarding ?? this.hasSeenOnboarding,
      isFirstTime: isFirstTime ?? this.isFirstTime,
      isHubConnected: isHubConnected ?? this.isHubConnected,
    );
  }
}

/// The core Authentication Provider that manages login, signup, and Google Auth.
/// It interacts directly with Firebase Auth and updates the [AuthState].
class AuthNotifier extends Notifier<AuthState> {
  final LocalStorageService _storage = LocalStorageService();
  final firebase.FirebaseAuth _auth = firebase.FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn.instance;

  @override
  AuthState build() {
    // When the app starts, immediately check if the user is already logged in
    Future.microtask(_checkLoginStatus);
    return const AuthState();
  }

  /// Checks local storage and Firebase to restore the user's session silently.
  Future<void> _checkLoginStatus() async {
    try {
      // Artificial delay to ensure the beautiful Splash Screen animations finish playing
      await Future.delayed(const Duration(seconds: 2));

      // 1. Fetch persistent flags from SharedPreferences
      final hasSeenOnboarding = await _storage.hasSeenOnboarding();
      final isFirstTime = await _storage.isFirstTime();
      final isHubConnected = await _storage.isHubConnected();

      // 2. Check if Firebase remembers a logged-in user
      final firebaseUser = _auth.currentUser;
      final isLogged = firebaseUser != null;

      if (isLogged) {
        // 3. Fetch local user if exists to preserve avatarUrl
        final cachedUser = await _storage.getUserByEmail(firebaseUser.email ?? '');

        final user = User(
          id: firebaseUser.uid,
          name: firebaseUser.displayName ?? 'User',
          email: firebaseUser.email ?? '',
          avatarUrl: cachedUser?.avatarUrl, // Preserve local profile pic
        );
        // Save to Riverpod's user provider
        ref.read(userProvider.notifier).setUser(user);
      }

      // 4. Update the UI state to stop loading and show the correct screen
      state = state.copyWith(
        isAuthenticated: isLogged,
        isInitializing: false,
        hasSeenOnboarding: hasSeenOnboarding,
        isFirstTime: isFirstTime,
        isHubConnected: isHubConnected,
      );
    } catch (e) {
      // If anything fails during startup, stop initializing and show error
      state = state.copyWith(isInitializing: false, error: e.toString());
    }
  }

  /// Handles standard Email & Password login via Firebase
  Future<bool> login(String email, String password) async {
    state = state.copyWith(isLoading: true, clearError: true); // Show spinner
    try {
      // Attempt Firebase login
      final userCredential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      // Save onboarding flag so they don't see the welcome screen again
      await _storage.setHasSeenOnboarding(true);

      // Create our local User model
      final user = User(
        id: userCredential.user!.uid,
        name: userCredential.user!.displayName ?? 'User',
        email: userCredential.user!.email!,
      );
      ref.read(userProvider.notifier).setUser(user);

      // Success! Update state
      state = state.copyWith(
        isAuthenticated: true,
        isLoading: false,
        hasSeenOnboarding: true,
      );
      return true;
    } on firebase.FirebaseAuthException catch (e) {
      // Firebase throws specific errors (e.g., wrong password, user not found)
      state = state.copyWith(
        isLoading: false,
        error: e.message ?? 'Login failed',
      );
      return false;
    }
  }

  /// Handles creating a new account via Firebase Email & Password
  Future<bool> signup(String name, String email, String password) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      // Create user in Firebase Auth
      final userCredential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      // Firebase Auth doesn't take a 'name' on creation, so we must update it immediately after
      await userCredential.user!.updateDisplayName(name);

      await _storage.setHasSeenOnboarding(true);

      final newUser = User(
        id: userCredential.user!.uid,
        name: name,
        email: email,
      );
      ref.read(userProvider.notifier).setUser(newUser);

      // Success!
      state = state.copyWith(
        isAuthenticated: true,
        isLoading: false,
        hasSeenOnboarding: true,
      );
      return true;
    } on firebase.FirebaseAuthException catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.message ?? 'Signup failed',
      );
      return false;
    }
  }

  /// Handles Google Sign-In (OAuth 2.0 flow)
  Future<void> signInWithGoogle() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      // 1. Initialize the Google Sign In SDK
      await _googleSignIn.initialize();

      // 2. Trigger the Google Account picker UI
      final GoogleSignInAccount googleUser = await _googleSignIn.authenticate();

      // 3. Get the raw authentication tokens
      final googleAuth = googleUser.authentication;

      // 4. Request authorization for Email and Profile scopes to get the Access Token
      final authorizedUser = await googleUser.authorizationClient
          .authorizeScopes(['email', 'profile']);

      // 5. Combine tokens into a Firebase Credential
      final credential = firebase.GoogleAuthProvider.credential(
        accessToken: authorizedUser.accessToken,
        idToken: googleAuth.idToken,
      );

      // 6. Sign in to Firebase using this Google Credential
      final userCredential = await _auth.signInWithCredential(credential);

      await _storage.setHasSeenOnboarding(true);

      // 7. Sync the new Google User into our local state
      final user = User(
        id: userCredential.user!.uid,
        name:
            userCredential.user!.displayName ??
            googleUser.displayName ??
            'User',
        email: userCredential.user!.email ?? googleUser.email,
      );
      ref.read(userProvider.notifier).setUser(user);

      state = state.copyWith(
        isAuthenticated: true,
        isLoading: false,
        hasSeenOnboarding: true,
      );
    } on firebase.FirebaseAuthException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: 'Google sign-in failed');
    }
  }

  /// Sends a password reset email via Firebase
  Future<bool> resetPassword(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
      return true;
    } on firebase.FirebaseAuthException catch (e) {
      state = state.copyWith(error: e.message);
      return false;
    }
  }

  /// Logs the user out and clears ALL cached data from RAM memory
  Future<void> logout() async {
    // 1. Sign out from remote services
    await _auth.signOut();
    await _googleSignIn.signOut();

    // 2. Clear local user profile
    ref.read(userProvider.notifier).clearUser();

    // 3. CRITICAL: Invalidate (reset) all Riverpod providers!
    // If we don't do this, the next user who logs in will see the previous user's devices/rooms.
    ref.invalidate(roomsProvider);
    ref.invalidate(devicesProvider);
    ref.invalidate(activityLogProvider);
    ref.invalidate(automationProvider);

    // 4. Update UI to push back to login screen
    state = state.copyWith(isAuthenticated: false);
  }

  /// Simulates connecting the physical Smart Home Hub (Raspberry Pi/ESP32)
  Future<void> simulateHubConnection({
    bool screenReader = false,
    bool voiceFeedback = false,
    bool visualAlerts = false,
  }) async {
    state = state.copyWith(isLoading: true);

    // Fake network delay for realism
    await Future.delayed(const Duration(seconds: 2));

    // Generate a fake Hub ID
    final randomPart = DateTime.now().millisecondsSinceEpoch
        .toString()
        .substring(8);
    final hubId = "RPI_$randomPart";

    // Save settings locally
    await _storage.setHubId(hubId);
    await _storage.setHubConnected(true);
    await _storage.saveAccessibilitySettings(
      screenReader: screenReader,
      voiceFeedback: voiceFeedback,
      visualAlerts: visualAlerts,
    );
    await _storage.setFirstTime(false);

    state = state.copyWith(
      isLoading: false,
      isHubConnected: true,
      isFirstTime: false,
    );
  }

  /// Marks the visual onboarding slider as completed
  Future<void> completeOnboarding() async {
    await _storage.setHasSeenOnboarding(true);
    state = state.copyWith(hasSeenOnboarding: true);
  }
}

/// Global provider to access AuthNotifier from anywhere in the app
final authProvider = NotifierProvider<AuthNotifier, AuthState>(
  AuthNotifier.new,
);

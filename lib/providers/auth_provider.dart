import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/user.dart';
import '../services/local_storage_service.dart';
import 'user_provider.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase;
import 'package:google_sign_in/google_sign_in.dart';

class AuthState {
  final bool isAuthenticated;
  final String? error;
  final bool isLoading;
  final bool isInitializing;
  final bool hasSeenOnboarding;
  final bool isFirstTime;
  final bool isHubConnected;

  const AuthState({
    this.isAuthenticated = false,
    this.error,
    this.isLoading = false,
    this.isInitializing = true,
    this.hasSeenOnboarding = false,
    this.isFirstTime = true,
    this.isHubConnected = false,
  });

  AuthState copyWith({
    bool? isAuthenticated,
    String? error,
    bool? isLoading,
    bool? isInitializing,
    bool? hasSeenOnboarding,
    bool? isFirstTime,
    bool? isHubConnected,
    bool clearError = false,
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

class AuthNotifier extends Notifier<AuthState> {
  final LocalStorageService _storage = LocalStorageService();
  final firebase.FirebaseAuth _auth = firebase.FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn.instance;

  @override
  AuthState build() {
    Future.microtask(_checkLoginStatus);
    return const AuthState();
  }

  Future<void> _checkLoginStatus() async {
    try {
      final hasSeenOnboarding = await _storage.hasSeenOnboarding();
      final isFirstTime = await _storage.isFirstTime();
      final isHubConnected = await _storage.isHubConnected();

      // Check Firebase current user instead of local storage
      final firebaseUser = _auth.currentUser;
      final isLogged = firebaseUser != null;

      if (isLogged) {
        // Sync Firebase user to your local User model/provider
        final user = User(
          id: firebaseUser.uid,
          name: firebaseUser.displayName ?? 'User',
          email: firebaseUser.email ?? '',
          // avatarUrl: firebaseUser.photoURL, // If your model supports this
        );
        ref.read(userProvider.notifier).setUser(user);
      }

      state = state.copyWith(
        isAuthenticated: isLogged,
        isInitializing: false,
        hasSeenOnboarding: hasSeenOnboarding,
        isFirstTime: isFirstTime,
        isHubConnected: isHubConnected,
      );
    } catch (e) {
      state = state.copyWith(isInitializing: false, error: e.toString());
    }
  }

  Future<bool> login(String email, String password) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final userCredential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      // Update local state
      await _storage.setHasSeenOnboarding(true);

      final user = User(
        id: userCredential.user!.uid,
        name: userCredential.user!.displayName ?? 'User',
        email: userCredential.user!.email!,
      );
      ref.read(userProvider.notifier).setUser(user);

      state = state.copyWith(
        isAuthenticated: true,
        isLoading: false,
        hasSeenOnboarding: true,
      );
      return true;
    } on firebase.FirebaseAuthException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message ?? 'Login failed');
      return false;
    }
  }

  Future<bool> signup(String name, String email, String password) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final userCredential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      // Update display name in Firebase
      await userCredential.user!.updateDisplayName(name);

      await _storage.setHasSeenOnboarding(true);

      final newUser = User(
        id: userCredential.user!.uid,
        name: name,
        email: email,
      );
      ref.read(userProvider.notifier).setUser(newUser);

      state = state.copyWith(
        isAuthenticated: true,
        isLoading: false,
        hasSeenOnboarding: true,
      );
      return true;
    } on firebase.FirebaseAuthException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message ?? 'Signup failed');
      return false;
    }
  }

  Future<void> signInWithGoogle() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      // FIX: Initialize the package (Mandatory for v7+)
      await _googleSignIn.initialize();

      // FIX: Trigger the new authentication flow using .authenticate()
      final GoogleSignInAccount? googleUser = await _googleSignIn.authenticate();
      if (googleUser == null) {
        state = state.copyWith(isLoading: false); // User canceled
        return;
      }

      // Obtain ID token from standard authentication
      final googleAuth = await googleUser.authentication;

      // FIX: Request explicit authorization to extract the Access Token
      final authorizedUser = await googleUser.authorizationClient.authorizeScopes(['email', 'profile']);

      // Create a new credential combining both tokens
      final credential = firebase.GoogleAuthProvider.credential(
        accessToken: authorizedUser.accessToken,
        idToken: googleAuth.idToken,
      );

      // Sign in to Firebase
      final userCredential = await _auth.signInWithCredential(credential);

      // Save onboarding state
      await _storage.setHasSeenOnboarding(true);

      // Sync with your User model
      final user = User(
        id: userCredential.user!.uid,
        name: userCredential.user!.displayName ?? googleUser.displayName ?? 'User',
        email: userCredential.user!.email ?? googleUser.email,
      );
      ref.read(userProvider.notifier).setUser(user);

      state = state.copyWith(isAuthenticated: true, isLoading: false, hasSeenOnboarding: true);
    } on firebase.FirebaseAuthException catch (e) {
      state = state.copyWith(isLoading: false, error: e.message);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: 'Google sign-in failed');
    }
  }

  Future<bool> resetPassword(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
      return true;
    } on firebase.FirebaseAuthException catch (e) {
      state = state.copyWith(error: e.message);
      return false;
    }
  }

  Future<void> logout() async {
    await _auth.signOut();
    await _googleSignIn.signOut();
    ref.read(userProvider.notifier).clearUser();
    state = state.copyWith(isAuthenticated: false);
  }

  Future<void> simulateHubConnection({
    bool screenReader = false,
    bool voiceFeedback = false,
    bool visualAlerts = false,
  }) async {
    state = state.copyWith(isLoading: true);
    
    // 3. Hub Connection: Simulate connection
    await Future.delayed(const Duration(seconds: 2));
    final randomPart = DateTime.now().millisecondsSinceEpoch.toString().substring(8);
    final hubId = "RPI_$randomPart";
    
    await _storage.setHubId(hubId);
    await _storage.setHubConnected(true);
    
    // 4. Accessibility Setup
    await _storage.saveAccessibilitySettings(
      screenReader: screenReader,
      voiceFeedback: voiceFeedback,
      visualAlerts: visualAlerts,
    );
    
    // 6. Completion
    await _storage.setFirstTime(false);
    
    state = state.copyWith(
      isLoading: false,
      isHubConnected: true,
      isFirstTime: false,
    );
  }

  Future<void> completeOnboarding() async {
    await _storage.setHasSeenOnboarding(true);
    state = state.copyWith(hasSeenOnboarding: true);
  }
}

final authProvider = NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);

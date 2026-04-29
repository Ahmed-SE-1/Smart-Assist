import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/user.dart';
import '../services/local_storage_service.dart';
import '../services/social_auth_service.dart';
import 'user_provider.dart';

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
  final SocialAuthService _socialAuth = SocialAuthService();
  @override
  AuthState build() {
    Future.microtask(_checkLoginStatus);
    return const AuthState();
  }

  Future<void> _checkLoginStatus() async {
    try {
      final isLogged = await _storage.isLoggedIn();
      final hasSeenOnboarding = await _storage.hasSeenOnboarding();
      
      final isFirstTime = await _storage.isFirstTime();
      final isHubConnected = await _storage.isHubConnected();
      
      if (isLogged) {
          await ref.read(userProvider.notifier).loadUser();
      }

      await Future.delayed(const Duration(seconds: 1));
      
      state = state.copyWith(
        isAuthenticated: isLogged,
        isInitializing: false,
        hasSeenOnboarding: hasSeenOnboarding,
        isFirstTime: isFirstTime,
        isHubConnected: isHubConnected,
      );
    } catch (e) {
      state = state.copyWith(isInitializing: false);
    }
  }

  Future<bool> login(String email, String password) async {
    state = state.copyWith(isLoading: true, clearError: true);
    await Future.delayed(const Duration(seconds: 1));
    
    final isValid = await _storage.verifyCredentials(email, password);
    if (!isValid) {
        state = state.copyWith(isLoading: false, error: 'Invalid email or password');
        return false;
    }
    
    final user = await _storage.getUserByEmail(email);
    if (user == null) {
         state = state.copyWith(isLoading: false, error: 'User data not found');
         return false;
    }
    
    await _storage.setLoggedIn(true);
    await _storage.saveUser(user);
    await _storage.setHasSeenOnboarding(true);
    ref.read(userProvider.notifier).setUser(user);

    final isFirstTime = await _storage.isFirstTime();
    final isHubConnected = await _storage.isHubConnected();

    state = state.copyWith(
      isAuthenticated: true, 
      isLoading: false, 
      hasSeenOnboarding: true,
      isFirstTime: isFirstTime,
      isHubConnected: isHubConnected,
    );
    return true;
  }

  Future<bool> signup(String name, String email, String password) async {
    state = state.copyWith(isLoading: true, clearError: true);
    await Future.delayed(const Duration(seconds: 1));
    
    final newUser = User(
      id: const Uuid().v4(),
      name: name,
      email: email,
    );
    
    await _storage.saveCredentials(email, password);
    await _storage.saveUser(newUser);
    await _storage.setLoggedIn(true);
    await _storage.setHasSeenOnboarding(true);
    ref.read(userProvider.notifier).setUser(newUser);

    final isFirstTime = await _storage.isFirstTime();
    final isHubConnected = await _storage.isHubConnected();

    state = state.copyWith(
      isAuthenticated: true, 
      isLoading: false, 
      hasSeenOnboarding: true,
      isFirstTime: isFirstTime,
      isHubConnected: isHubConnected,
    );
    return true;
  }

  Future<void> socialLogin(String provider) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await Future.delayed(const Duration(milliseconds: 500));
      state = state.copyWith(isLoading: false, error: 'AUTH_CONFIG_ERROR');
    } catch (e) {
      state = state.copyWith(isLoading: false, error: 'AUTH_CONFIG_ERROR');
    }
  }

  Future<void> loginWithMockSocial(String name, String email, String? id, String? avatarUrl) async {
    state = state.copyWith(isLoading: true, clearError: true);
    await Future.delayed(const Duration(milliseconds: 800));

    User? user = await _storage.getUserByEmail(email);

    if (user == null) {
      user = User(
        id: id ?? const Uuid().v4(),
        name: name,
        email: email,
        avatarUrl: avatarUrl,
      );
      await _storage.saveUser(user);
      await _storage.saveCredentials(email, 'social123');
    }

    await _storage.setLoggedIn(true);
    await _storage.setHasSeenOnboarding(true);
    ref.read(userProvider.notifier).setUser(user);
    
    final isFirstTime = await _storage.isFirstTime();
    final isHubConnected = await _storage.isHubConnected();

    state = state.copyWith(
      isAuthenticated: true, 
      isLoading: false, 
      hasSeenOnboarding: true,
      isFirstTime: isFirstTime,
      isHubConnected: isHubConnected,
    );
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

  Future<void> logout() async {
    await _storage.clearUser();
    ref.read(userProvider.notifier).clearUser();
    state = state.copyWith(isAuthenticated: false);
  }
}

final authProvider = NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);

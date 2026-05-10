import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';

import '../providers/auth_provider.dart';
import '../models/user.dart'; // IMPORTANT: UserRole enum ke liye add kiya gaya

import '../screens/splash_screen.dart';
import '../screens/onboarding/onboarding_screen.dart';
import '../screens/onboarding/hub_connection_screen.dart';
import '../screens/rooms/room_detail_screen.dart';
import '../screens/auth/login_screen.dart';
import '../screens/auth/register_screen.dart';
import '../screens/auth/role_selection_screen.dart'; // Role Selection Screen Import

import '../screens/main_layout.dart';
import '../screens/dashboard/dashboard_screen.dart';
import '../screens/features/automation/automation_screen.dart';
import '../screens/alerts/alerts_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../screens/features/gesture/gesture_screen.dart';
import '../screens/features/voice/voice_screen.dart';

/// A custom notifier that bridges Riverpod state changes with GoRouter's refresh mechanism.
class RouterNotifier extends ChangeNotifier {
  final Ref _ref;
  RouterNotifier(this._ref) {
    _ref.listen(authProvider, (_, __) => notifyListeners());
  }
}

/// The global routing provider that defines all the screens and navigation rules in the app.
final routerProvider = Provider<GoRouter>((ref) {
  final notifier = RouterNotifier(ref);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: notifier,

    redirect: (context, state) {
      final authState = ref.read(authProvider);

      if (authState.isInitializing) return '/';

      final isAuth = authState.isAuthenticated;
      final hasSeenOnboarding = authState.hasSeenOnboarding;
      final isFirstTime = authState.isFirstTime;
      final isHubConnected = authState.isHubConnected;

      // UPDATED: Added /role-selection to auth routes
      final isGoingToAuth = state.matchedLocation == '/login' ||
          state.matchedLocation == '/register' ||
          state.matchedLocation == '/role-selection';

      final isGoingToOnboarding = state.matchedLocation == '/onboarding';
      final isGoingToHub = state.matchedLocation == '/hub_connection';
      final isSplash = state.matchedLocation == '/';

      // LOGIC FOR UNAUTHENTICATED USERS:
      if (!isAuth) {
        if (!hasSeenOnboarding && !isGoingToOnboarding) return '/onboarding';
        if (hasSeenOnboarding && !isGoingToAuth) return '/login';
      }
      // LOGIC FOR AUTHENTICATED USERS:
      else {
        if (isFirstTime && !isGoingToHub) {
          return '/hub_connection';
        }
        if (!isHubConnected && !isGoingToHub) {
          return '/hub_connection';
        }

        if ((isGoingToAuth || isSplash || isGoingToOnboarding || isGoingToHub) && !isFirstTime && isHubConnected) {
          return '/home';
        }
      }

      return null;
    },
    routes: [
      // --- UNPROTECTED / SETUP ROUTES ---
      GoRoute(
        path: '/hub_connection',
        builder: (context, state) => const HubConnectionScreen(),
      ),
      GoRoute(
        path: '/',
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
      ),

      // NEW: Role Selection Route
      GoRoute(
        path: '/role-selection',
        builder: (context, state) => const RoleSelectionScreen(),
      ),

      // UPDATED: Register Route with Role extraction
      GoRoute(
        path: '/register',
        builder: (context, state) {
          // Extra se data nikal kar cast kar rahe hain.
          // Agar direct URL hit hota hai toh fallback default member set kardiya.
          final role = state.extra is UserRole ? state.extra as UserRole : UserRole.member;
          return RegisterScreen(selectedRole: role);
        },
      ),

      // --- PROTECTED ROUTES (Require Login & Hub Connection) ---
      ShellRoute(
        builder: (context, state, child) => MainLayout(child: child),
        routes: [
          GoRoute(
              path: '/home',
              builder: (context, state) => const DashboardScreen(),
              routes: [
                GoRoute(
                  path: 'gesture',
                  builder: (context, state) => const GestureScreen(),
                ),
                GoRoute(
                  path: 'voice',
                  builder: (context, state) => const VoiceScreen(),
                ),
              ]
          ),
          GoRoute(
            path: '/automation',
            builder: (context, state) => const AutomationScreen(),
          ),
          GoRoute(
            path: '/alerts',
            builder: (context, state) => const AlertsScreen(),
          ),
          GoRoute(
            path: '/room/:name',
            builder: (context, state) => RoomDetailScreen(roomName: state.pathParameters['name'] ?? 'Room'),
          ),
          GoRoute(
            path: '/settings',
            builder: (context, state) => const SettingsScreen(),
          ),
        ],
      ),
    ],
  );
});
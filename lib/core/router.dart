import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';

import '../screens/splash_screen.dart';
import '../screens/onboarding/onboarding_screen.dart';
import '../screens/onboarding/hub_connection_screen.dart';
import '../screens/rooms/room_detail_screen.dart';
import '../screens/auth/login_screen.dart';
import '../screens/auth/register_screen.dart';

import '../screens/main_layout.dart';
import '../screens/dashboard/dashboard_screen.dart';
import '../screens/features/automation/automation_screen.dart';
import '../screens/alerts/alerts_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../screens/features/gesture/gesture_screen.dart';
import '../screens/features/voice/voice_screen.dart';

import 'package:flutter/material.dart';

/// A custom notifier that bridges Riverpod state changes with GoRouter's refresh mechanism.
/// Whenever the [authProvider] state changes (e.g. user logs in, completes onboarding),
/// this class notifies GoRouter to re-evaluate the redirect logic.
class RouterNotifier extends ChangeNotifier {
  final Ref _ref;
  RouterNotifier(this._ref) {
    // Listen to changes in the Authentication state.
    // If the user's auth status changes, we call notifyListeners() which triggers a route refresh.
    _ref.listen(authProvider, (_, __) => notifyListeners());
  }
}

/// The global routing provider that defines all the screens and navigation rules in the app.
/// It uses the `go_router` package for declarative routing.
final routerProvider = Provider<GoRouter>((ref) {
  final notifier = RouterNotifier(ref);

  return GoRouter(
    initialLocation: '/', // Start at the splash screen
    refreshListenable: notifier, // Re-route if the notifier triggers
    
    // The redirect logic acts as a global guard for all routes.
    // It intercepts every navigation attempt and decides if the user is allowed to proceed.
    redirect: (context, state) {
      final authState = ref.read(authProvider);

      // If the app is still booting up and loading local storage, force them to stay on the Splash screen
      if (authState.isInitializing) return '/';
      
      final isAuth = authState.isAuthenticated;
      final hasSeenOnboarding = authState.hasSeenOnboarding;
      final isFirstTime = authState.isFirstTime;
      final isHubConnected = authState.isHubConnected;
      
      final isGoingToAuth = state.matchedLocation == '/login' || state.matchedLocation == '/register';
      final isGoingToOnboarding = state.matchedLocation == '/onboarding';
      final isGoingToHub = state.matchedLocation == '/hub_connection';
      final isSplash = state.matchedLocation == '/';
      
      // LOGIC FOR UNAUTHENTICATED USERS:
      if (!isAuth) {
        // If they haven't seen the welcome tutorial, force them to onboarding
        if (!hasSeenOnboarding && !isGoingToOnboarding) return '/onboarding';
        
        // If they have seen the tutorial, but aren't trying to log in/register, force them to login
        if (hasSeenOnboarding && !isGoingToAuth) return '/login';
      } 
      // LOGIC FOR AUTHENTICATED USERS:
      else {
        // If it's their first time logging in, force them to the Hub Connection screen
        if (isFirstTime && !isGoingToHub) {
          return '/hub_connection';
        }
        
        // If their hardware hub isn't connected, force them to the Hub Connection screen
        if (!isHubConnected && !isGoingToHub) {
          return '/hub_connection';
        }

        // If they are fully setup (logged in, seen onboarding, hub connected)
        // and they try to visit Splash, Login, or Onboarding, redirect them straight to the Home Dashboard
        if ((isGoingToAuth || isSplash || isGoingToOnboarding || isGoingToHub) && !isFirstTime && isHubConnected) {
          return '/home';
        }
      }

      // Return null to allow the requested navigation to proceed normally
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
      GoRoute(
        path: '/register',
        builder: (context, state) => const RegisterScreen(),
      ),
      
      // --- PROTECTED ROUTES (Require Login & Hub Connection) ---
      // ShellRoute is used to wrap nested routes in a common persistent UI (like a bottom navigation bar)
      ShellRoute(
        builder: (context, state, child) => MainLayout(child: child),
        routes: [
          GoRoute(
            path: '/home',
            builder: (context, state) => const DashboardScreen(),
            routes: [
              // Nested routes inside Home (e.g., /home/gesture)
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
          // Dynamic route that takes the room name as a parameter (e.g., /room/Kitchen)
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

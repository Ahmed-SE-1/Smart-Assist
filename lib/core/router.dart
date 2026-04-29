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

class RouterNotifier extends ChangeNotifier {
  final Ref _ref;
  RouterNotifier(this._ref) {
    _ref.listen(authProvider, (_, __) => notifyListeners());
  }
}

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
      
      final isGoingToAuth = state.matchedLocation == '/login' || state.matchedLocation == '/register';
      final isGoingToOnboarding = state.matchedLocation == '/onboarding';
      final isGoingToHub = state.matchedLocation == '/hub_connection';
      final isSplash = state.matchedLocation == '/';
      final isDashboardOrChild = state.matchedLocation.startsWith('/home') || state.matchedLocation.startsWith('/room') || state.matchedLocation == '/automation' || state.matchedLocation == '/alerts' || state.matchedLocation == '/settings';

      if (!isAuth) {
        if (!hasSeenOnboarding && !isGoingToOnboarding) return '/onboarding';
        if (hasSeenOnboarding && !isGoingToAuth) return '/login';
      } else {
        if (isFirstTime && !isGoingToHub) {
          return '/hub_connection';
        }
        
        if (!isHubConnected && isDashboardOrChild) {
          return '/hub_connection';
        }

        if ((isGoingToAuth || isSplash || isGoingToOnboarding || isGoingToHub) && !isFirstTime && isHubConnected) {
          return '/home';
        }
      }

      return null;
    },
    routes: [
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

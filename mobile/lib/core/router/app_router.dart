import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mesenger/core/state/app_state.dart';
import 'package:mesenger/features/banned/banned_screen.dart';
import 'package:mesenger/features/chat/chat_screen.dart';
import 'package:mesenger/features/contacts/contact_profile_screen.dart';
import 'package:mesenger/features/dating/dating_profile_screen.dart';
import 'package:mesenger/features/dating/dating_screen.dart';
import 'package:mesenger/features/home/home_shell.dart';
import 'package:mesenger/data/models/space.dart';
import 'package:mesenger/features/lock/lock_screen.dart';
import 'package:mesenger/features/onboarding/invite_screen.dart';
import 'package:mesenger/features/onboarding/lock_setup_screen.dart';
import 'package:mesenger/features/onboarding/profile_setup_screen.dart';
import 'package:mesenger/features/onboarding/server_setup_screen.dart';
import 'package:mesenger/features/settings/public_servers_screen.dart';
import 'package:mesenger/features/onboarding/welcome_screen.dart';
import 'package:mesenger/features/settings/edit_profile_screen.dart';
import 'package:mesenger/features/settings/server_manager_screen.dart';
import 'package:mesenger/features/settings/settings_screen.dart';
import 'package:mesenger/features/settings/space_settings_screen.dart';
import 'package:mesenger/features/settings/spaces_screen.dart';
import 'package:mesenger/features/splash/splash_screen.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    navigatorKey: rootNavigatorKey,
    refreshListenable: _RouterRefresh(ref),
    redirect: (context, state) {
      final app = ref.read(appStateProvider);
      final loc = state.uri.toString();
      if (!app.bootstrapped) {
        return loc == '/' ? null : '/';
      }
      if (app.banned) {
        return loc == BannedScreen.route ? null : BannedScreen.route;
      }
      if (app.user == null) {
        const onboardingPaths = [
          OnboardingWelcomeScreen.route,
          ServerSetupScreen.route,
          InviteScreen.route,
          ProfileSetupScreen.route,
          LockSetupScreen.route,
        ];
        if (onboardingPaths.contains(loc)) return null;
        return OnboardingWelcomeScreen.route;
      }
      if (app.lockEnabled && !app.lockUnlocked) {
        return loc == LockScreen.route ? null : LockScreen.route;
      }
      if (app.lockEnabled && app.lockUnlocked && loc == LockScreen.route) {
        return HomeShell.route;
      }
      const allowedPaths = [
        OnboardingWelcomeScreen.route,
        ServerSetupScreen.route,
        InviteScreen.route,
        ProfileSetupScreen.route,
        LockSetupScreen.route,
      ];
      if (allowedPaths.contains(loc)) return null;
      if (loc == '/' || loc.isEmpty) return HomeShell.route;
      return null;
    },
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: OnboardingWelcomeScreen.route,
        builder: (context, state) => const OnboardingWelcomeScreen(),
      ),
      GoRoute(
        path: ServerSetupScreen.route,
        builder: (context, state) => const ServerSetupScreen(),
      ),
      GoRoute(
        path: PublicServersScreen.route,
        builder: (context, state) => const PublicServersScreen(),
      ),
      GoRoute(
        path: InviteScreen.route,
        builder: (context, state) => const InviteScreen(),
      ),
      GoRoute(
        path: ProfileSetupScreen.route,
        builder: (context, state) => const ProfileSetupScreen(),
      ),
      GoRoute(
        path: LockSetupScreen.route,
        builder: (context, state) => const LockSetupScreen(),
      ),
      GoRoute(
        path: LockScreen.route,
        builder: (context, state) => const LockScreen(),
      ),
      GoRoute(
        path: BannedScreen.route,
        builder: (context, state) => const BannedScreen(),
      ),
      GoRoute(
        path: HomeShell.route,
        builder: (context, state) => const HomeShell(),
        routes: [
          GoRoute(
            path: 'chat/:chatId',
            builder: (context, state) => ChatScreen(
              chatId: state.pathParameters['chatId']!,
            ),
          ),
          GoRoute(
            path: 'contact/:handle',
            builder: (context, state) => ContactProfileScreen(
              handle: state.pathParameters['handle']!,
            ),
          ),
          GoRoute(
            path: 'insiders',
            builder: (context, state) => const DatingScreen(),
          ),
          GoRoute(
            path: 'dating-profile/:handle',
            builder: (context, state) => DatingProfileScreen(
              handle: state.pathParameters['handle']!,
            ),
          ),
          GoRoute(
            path: 'spaces',
            builder: (context, state) => const SpacesScreen(),
          ),
          GoRoute(
            path: 'spaces/:spaceId/settings',
            builder: (context, state) {
              final spaceId = int.tryParse(state.pathParameters['spaceId'] ?? '') ?? 0;
              final space = Space(
                id: spaceId,
                name: state.uri.queryParameters['name'] ?? 'Пространство',
                description: state.uri.queryParameters['description'] ?? '',
                ownerId: int.tryParse(state.uri.queryParameters['owner'] ?? '') ?? 0,
              );
              return SpaceSettingsScreen(space: space);
            },
          ),
          GoRoute(
            path: 'lock-settings',
            builder: (context, state) => const LockSetupScreen(),
          ),
          GoRoute(
            path: 'servers',
            builder: (context, state) => const ServerManagerScreen(),
          ),
          GoRoute(
            path: 'settings',
            builder: (context, state) => const SettingsScreen(),
          ),
          GoRoute(
            path: 'profile/edit',
            builder: (context, state) => const EditProfileScreen(),
          ),
        ],
      ),
    ],
  );
});

class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(Ref ref) {
    ref.listen(appStateProvider, (prev, next) => notifyListeners());
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mesenger/core/constants/app_strings.dart';
import 'package:mesenger/features/chat/chats_screen.dart';
import 'package:mesenger/features/contacts/contacts_screen.dart';
import 'package:mesenger/features/settings/settings_screen.dart';
import 'package:mesenger/features/spaces/spaces_tab_screen.dart';

class HomeShell extends ConsumerStatefulWidget {
  static const route = '/home';

  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: const [
          ChatsScreen(),
          ContactsScreen(),
          SpacesTabScreen(),
          SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), selectedIcon: Icon(Icons.chat_bubble), label: S.chats),
          NavigationDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people), label: S.contacts),
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Пространства'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: S.settings),
        ],
      ),
    );
  }
}

/// Signed-in shell.
///
/// The primary navigation is four destinations: **Accueil | Historique |
/// Profil | Paramètres**. The bell in the app bar stays the single entry point
/// to notifications, and the admin dashboard is still reached from the overflow
/// menu, offered only when the server-reported role says so.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/auth_controller.dart';
import '../state/notifications_controller.dart';
import 'screens/admin_dashboard_screen.dart';
import 'screens/home_screen.dart';
import 'screens/my_requests_screen.dart';
import 'screens/notifications_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/settings_screen.dart';
import 'widgets/tango_scaffold.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

/// Lets a hosted screen drive the shell's own navigation without reaching into
/// its private state — the Home avatar opens the "Profil" destination exactly
/// as tapping that tab does, instead of pushing a second, unrelated route.
class AppShellScope extends InheritedWidget {
  const AppShellScope({super.key, required this.goToProfile, required super.child});

  final VoidCallback goToProfile;

  static AppShellScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppShellScope>();

  @override
  bool updateShouldNotify(AppShellScope oldWidget) => false;
}

class _AppShellState extends State<AppShell> {
  static const int _profileIndex = 2;

  int _index = 0;

  void _open(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  void _goToProfile() => setState(() => _index = _profileIndex);

  void _openNotifications() {
    _open(const NotificationsScreen());
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = context.watch<AuthController>().isAdmin;
    // Server-scoped, per-user notifications: the badge can only reflect rows
    // RLS already limited to this account.
    final unread = context.watch<NotificationsController>().unreadCount;

    const destinations = <_Destination>[
      _Destination(
        'Accueil',
        Icons.home_outlined,
        Icons.home_rounded,
        HomeScreen(),
      ),
      _Destination(
        'Historique',
        Icons.receipt_long_outlined,
        Icons.receipt_long_rounded,
        MyRequestsScreen(embedded: true),
      ),
      _Destination(
        'Profil',
        Icons.person_outline_rounded,
        Icons.person_rounded,
        ProfileScreen(embedded: true),
      ),
      _Destination(
        'Paramètres',
        Icons.settings_outlined,
        Icons.settings_rounded,
        SettingsScreen(embedded: true),
      ),
    ];

    return AppShellScope(
      goToProfile: _goToProfile,
      child: TangoKycScaffold(
        // The Home carries the brand itself, so the shell leaves that tab's bar
        // untitled: one brand block, not two "Tango KYC" a few pixels apart.
        appBar: AppBar(
          title: Text(_index == 0 ? '' : destinations[_index].label),
          actions: [
            IconButton(
              onPressed: _openNotifications,
              tooltip: 'Notifications',
              icon: unread > 0
                  ? Badge.count(
                      count: unread,
                      child: const Icon(Icons.notifications_none_rounded),
                    )
                  : const Icon(Icons.notifications_none_rounded),
            ),
            // Profile and Settings are now tabs, so only the admin dashboard is
            // left in the overflow menu — and only for an admin.
            if (isAdmin)
              PopupMenuButton<_MenuAction>(
                tooltip: 'Menu',
                onSelected: (action) {
                  switch (action) {
                    case _MenuAction.admin:
                      _open(const AdminDashboardScreen());
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: _MenuAction.admin,
                    child: ListTile(
                      leading: Icon(Icons.admin_panel_settings_outlined),
                      title: Text('Administration'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
          ],
        ),
        body: IndexedStack(
          index: _index,
          children: [for (final destination in destinations) destination.screen],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (value) => setState(() => _index = value),
          destinations: [
            for (final destination in destinations)
              NavigationDestination(
                icon: Icon(destination.icon),
                selectedIcon: Icon(destination.selectedIcon),
                label: destination.label,
              ),
          ],
        ),
      ),
    );
  }
}

enum _MenuAction { admin }

class _Destination {
  const _Destination(this.label, this.icon, this.selectedIcon, this.screen);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget screen;
}

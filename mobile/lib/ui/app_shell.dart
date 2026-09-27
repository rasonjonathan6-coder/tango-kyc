/// Signed-in shell.
///
/// The primary navigation is deliberately just two destinations:
/// **Accueil | Historique**. Notifications live behind a bell in the app bar,
/// and everything else (profile, settings, the admin dashboard) is reached from
/// the overflow menu so the home screen stays focused on creating and tracking a
/// request.
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

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  void _open(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

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
      _Destination('Accueil', Icons.home_outlined, Icons.home_rounded, HomeScreen()),
      _Destination('Historique', Icons.receipt_long_outlined, Icons.receipt_long_rounded,
          MyRequestsScreen()),
    ];

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(_index == 0 ? 'Tango KYC' : destinations[_index].label),
        actions: [
          IconButton(
            onPressed: _openNotifications,
            tooltip: 'Notifications',
            icon: unread > 0
                ? Badge.count(count: unread, child: const Icon(Icons.notifications_none_rounded))
                : const Icon(Icons.notifications_none_rounded),
          ),
          PopupMenuButton<_MenuAction>(
            tooltip: 'Menu',
            onSelected: (action) {
              switch (action) {
                case _MenuAction.profile:
                  _open(const ProfileScreen());
                case _MenuAction.settings:
                  _open(const SettingsScreen());
                case _MenuAction.admin:
                  _open(const AdminDashboardScreen());
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _MenuAction.profile,
                child: ListTile(
                  leading: Icon(Icons.person_outline_rounded),
                  title: Text('Profil'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: _MenuAction.settings,
                child: ListTile(
                  leading: Icon(Icons.settings_outlined),
                  title: Text('Paramètres'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              // Admin is only offered when the server-reported role says so; the
              // backend re-checks the role on every admin call regardless.
              if (isAdmin)
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
    );
  }
}

enum _MenuAction { profile, settings, admin }

class _Destination {
  const _Destination(this.label, this.icon, this.selectedIcon, this.screen);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget screen;
}

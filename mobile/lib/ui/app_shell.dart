/// Signed-in shell with bottom navigation: Home, My Requests, the admin
/// dashboard (only for admins) and Profile.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/auth_controller.dart';
import 'screens/admin_dashboard_screen.dart';
import 'screens/home_screen.dart';
import 'screens/my_requests_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/settings_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final isAdmin = context.watch<AuthController>().isAdmin;
    // The admin tab is only offered when the server-reported role says so. The
    // backend re-checks the role on every admin call regardless of the UI.
    final destinations = <_Destination>[
      const _Destination('Home', Icons.home_outlined, Icons.home_rounded, HomeScreen()),
      const _Destination('Requests', Icons.receipt_long_outlined, Icons.receipt_long_rounded,
          MyRequestsScreen()),
      if (isAdmin)
        const _Destination('Admin', Icons.admin_panel_settings_outlined,
            Icons.admin_panel_settings_rounded, AdminDashboardScreen()),
      const _Destination(
          'Profile', Icons.person_outline_rounded, Icons.person_rounded, ProfileScreen()),
      const _Destination(
          'Settings', Icons.settings_outlined, Icons.settings_rounded, SettingsScreen()),
    ];

    if (_index >= destinations.length) _index = destinations.length - 1;

    return Scaffold(
      appBar: AppBar(
        title: Text(destinations[_index].label == 'Home'
            ? 'Tango KYC Verification'
            : destinations[_index].label),
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

class _Destination {
  const _Destination(this.label, this.icon, this.selectedIcon, this.screen);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget screen;
}

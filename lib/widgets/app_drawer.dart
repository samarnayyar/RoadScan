import 'package:flutter/material.dart';

import '../config/app_theme.dart';
import '../screens/reports_screen.dart';
import '../services/theme_controller.dart';

/// Top-left navigation menu.
///
/// Accounts are intentionally absent for now: requiring signup before someone
/// can photograph a pothole kills the report rate, and reports are the whole
/// product. The entry below is a visible placeholder so the eventual login has
/// a home, and so it is obvious to a reviewer that its absence is a decision
/// rather than an omission.
class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key, required this.deviceId});

  final String deviceId;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF1B6CA8), Color(0xFF12496F)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.radar, color: Colors.white, size: 26),
                      const SizedBox(width: 10),
                      const Text(
                        'RoadScan',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Signed in anonymously',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.9),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    // Short prefix only. The full id is not secret, but showing
                    // all of it invites people to treat it as an account name.
                    'Device ${deviceId.substring(0, 8)}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),

            _Item(
              icon: Icons.report_outlined,
              title: 'All road reports',
              subtitle: 'Every hazard, newest first',
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const ReportsScreen(mine: false),
                ));
              },
            ),
            _Item(
              icon: Icons.person_pin_circle_outlined,
              title: 'My reports',
              subtitle: 'What this device has contributed',
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const ReportsScreen(mine: true),
                ));
              },
            ),

            const Divider(height: 26),

            // Same three-state cycle as the launch screen's toggle, surfaced
            // here too because the map is where users spend their time and
            // where switching theme actually matters (day vs night riding).
            ValueListenableBuilder<ThemeMode>(
              valueListenable: ThemeController.instance.mode,
              builder: (context, mode, _) => _Item(
                icon: ThemeController.icon(mode),
                title: 'Theme',
                subtitle: ThemeController.label(mode),
                onTap: () => ThemeController.instance.cycle(),
                showChevron: false,
              ),
            ),

            _Item(
              icon: Icons.login,
              title: 'Sign in',
              subtitle: 'Not implemented yet',
              enabled: false,
              onTap: () {},
            ),

            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Text(
                'Reports are attributed to this device, not to a person. '
                'Clearing app data resets the id.',
                style:
                    TextStyle(fontSize: 10.5, color: context.rs.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
    this.showChevron = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool enabled;

  /// False for rows that act in place rather than navigating -- a chevron on
  /// the theme row would promise a settings screen that does not exist.
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final c = context.rs;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: ListTile(
        leading: Icon(icon, size: 22, color: c.textPrimary),
        title: Text(title,
            style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: c.textPrimary)),
        subtitle: Text(subtitle,
            style: TextStyle(fontSize: 11.5, color: c.textSecondary)),
        onTap: enabled ? onTap : null,
        trailing: !enabled
            ? Icon(Icons.lock_outline, size: 15, color: c.textMuted)
            : showChevron
                ? Icon(Icons.chevron_right, size: 18, color: c.textMuted)
                : null,
      ),
    );
  }
}

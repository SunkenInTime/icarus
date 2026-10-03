import 'package:flutter/material.dart';
import 'package:convex_flutter/convex_flutter.dart';
import 'screens/home_screen.dart';
import 'screens/authentication_screen.dart';
import 'screens/messaging_screen.dart';
import 'screens/connection_screen.dart';
import 'screens/advanced_screen.dart';
import 'widgets/connection_status_indicator.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await ConvexClient.initialize(
    ConvexConfig(
      deploymentUrl: "https://merry-grasshopper-563.convex.cloud",
      clientId: "flutter-app-1.0",
      operationTimeout: const Duration(seconds: 30),
      healthCheckQuery: "health:ping",
    ),
  );

  runApp(const ConvexExampleApp());
}

class ConvexExampleApp extends StatelessWidget {
  const ConvexExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Convex Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const MainNavigationScreen(),
    );
  }
}

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _selectedIndex = 0;

  final List<Widget> _screens = const [
    HomeScreen(),
    AuthenticationScreen(),
    MessagingScreen(),
    ConnectionScreen(),
    AdvancedScreen(),
  ];

  final List<NavigationItem> _navItems = const [
    NavigationItem(
      icon: Icons.home,
      label: 'Home',
      description: 'Welcome and overview',
    ),
    NavigationItem(
      icon: Icons.login,
      label: 'Authentication',
      description: 'JWT tokens, auto-refresh, auth state',
    ),
    NavigationItem(
      icon: Icons.message,
      label: 'Messaging',
      description: 'Query, mutation, subscribe, live updates',
    ),
    NavigationItem(
      icon: Icons.wifi,
      label: 'Connection',
      description: 'WebSocket state, health checks, reconnect',
    ),
    NavigationItem(
      icon: Icons.settings,
      label: 'Advanced',
      description: 'Timeouts, actions, error handling, lifecycle',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_navItems[_selectedIndex].label),
        actions: const [
          ConnectionStatusIndicator(),
        ],
      ),
      drawer: _buildDrawer(),
      body: _screens[_selectedIndex],
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Theme.of(context).colorScheme.primary,
                  Theme.of(context).colorScheme.primaryContainer,
                ],
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.cloud, color: Colors.white, size: 48),
                const SizedBox(height: 8),
                const Text(
                  'Convex Flutter',
                  style: TextStyle(color: Colors.white, fontSize: 24,
                    fontWeight: FontWeight.bold),
                ),
                const Text(
                  'Example App',
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
                const Spacer(),
                // Auth state indicator in drawer
                StreamBuilder<bool>(
                  stream: ConvexClient.instance.authState,
                  initialData: false,
                  builder: (context, snapshot) {
                    final isAuth = snapshot.data ?? false;
                    return Row(
                      children: [
                        Icon(
                          isAuth ? Icons.verified_user : Icons.person_off,
                          color: Colors.white70,
                          size: 16,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          isAuth ? 'Authenticated' : 'Not Authenticated',
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
          ...List.generate(_navItems.length, (index) {
            final item = _navItems[index];
            return ListTile(
              leading: Icon(item.icon),
              title: Text(item.label),
              subtitle: Text(item.description, style: const TextStyle(fontSize: 12)),
              selected: _selectedIndex == index,
              selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
              onTap: () {
                setState(() => _selectedIndex = index);
                Navigator.pop(context);
              },
            );
          }),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            subtitle: const Text('Convex Flutter SDK v2.0.0', style: TextStyle(fontSize: 12)),
            onTap: () {
              Navigator.pop(context);
              showAboutDialog(
                context: context,
                applicationName: 'Convex Flutter',
                applicationVersion: '2.0.0',
                applicationIcon: const Icon(Icons.cloud, size: 48),
                children: const [
                  Text('Comprehensive example app demonstrating all features of the Convex Flutter SDK.'),
                  SizedBox(height: 8),
                  Text('Features:\n'
                       '• Real-time subscriptions\n'
                       '• Authentication & token refresh\n'
                       '• WebSocket connection state\n'
                       '• Query, mutation, and action support\n'
                       '• Lifecycle management'),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class NavigationItem {
  final IconData icon;
  final String label;
  final String description;

  const NavigationItem({
    required this.icon,
    required this.label,
    required this.description,
  });
}

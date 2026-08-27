# Convex Flutter

<p align="center">
  <table>
    <tr>
      <td><img src="example/screenshots/app_screenshot.png" alt="Home Screen" width="250"/></td>
      <td><img src="example/screenshots/messaging_screenshot.png" alt="Messaging Screen" width="250"/></td>
    </tr>
    <tr>
      <td align="center"><b>Home Screen</b></td>
      <td align="center"><b>Real-time Messaging</b></td>
    </tr>
  </table>
</p>

A Flutter plugin for integrating with the Convex backend. It provides a simple Dart API over the Convex Rust core to run queries, mutations, and actions, and to subscribe to real-time updates.

This package wraps the [Convex Rust library](https://github.com/get-convex/convex-rs) and exposes a Flutter-friendly interface.

## Features

- Real-time subscriptions to Convex queries
- Simple Dart API for queries, mutations, and actions
- Authentication with automatic token refresh
- Auth state stream for reactive UI updates
- **WebSocket connection state** - Real-time connection status monitoring via streams
- **Operation timeouts** - Configurable timeout for all queries, mutations, and actions
- **Lifecycle monitoring** - Stream of app lifecycle events (foreground/background)
- **Connection management** - Manual connection checking and reconnect functionality
- **Singleton pattern** - Access client anywhere via `ConvexClient.instance`
- **Multi-platform support** - Works on Web (pure Dart), Android, iOS, macOS, Windows, and Linux (FFI)

## Installation

Add the package to your Flutter project:

```bash
flutter pub add convex_flutter
```

That's it! The health check query mentioned below is optional - you can start using the SDK immediately without it.

## Platform Configuration

**Important**: Some platforms require additional configuration for network access. This is a one-time setup.

| Platform | Configuration Required |
|----------|------------------------|
| **Web** | ✅ None - works automatically |
| **iOS** | ✅ None - works automatically |
| **macOS** | ⚠️ **Network entitlements required** |
| **Android** | ⚠️ **INTERNET permission required** |
| **Windows** | ✅ None - works automatically |
| **Linux** | ✅ None - works automatically |

### Quick Setup

**macOS**: Add network entitlements to `macos/Runner/DebugProfile.entitlements` and `Release.entitlements`:

```xml
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.network.server</key>
<true/>
```

**Android**: Add internet permission to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

**📖 See [PLATFORM_CONFIGURATION.md](PLATFORM_CONFIGURATION.md) for complete setup instructions and troubleshooting.**

## Requirements

- Dart SDK >= 3.8.1 and Flutter >= 3.3.0
- **Web platform**: No additional requirements (uses pure Dart implementation)
- **Native platforms** (Android, iOS, macOS, Windows, Linux):
  - Rust toolchain (rustup + cargo) for building native code
  - Platform-specific toolchains:
    - Android: JDK 11 and Android SDK/NDK
    - iOS/macOS: Xcode and CocoaPods
    - Windows: Visual Studio Build Tools (C++)
    - Linux: clang, pkg-config, and build essentials

## Quick start

### Optional: Create a Health Check Query (Recommended)

For connection monitoring and health checks, it's recommended to create a lightweight health check query in your Convex backend. This is **optional** but provides a clean way to verify connectivity without side effects.

Create a file `convex/health.ts` in your Convex backend:

```typescript
// convex/health.ts
import { query } from "./_generated/server";

export const ping = query({
  args: {},
  handler: async () => {
    return "ok";
  },
});
```

This creates a lightweight endpoint at `health:ping` that you can use for connection health checks. It has no side effects and returns instantly.

### Initialize the Client

```dart
import 'package:convex_flutter/convex_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize the client once (singleton)
  await ConvexClient.initialize(
    ConvexConfig(
      deploymentUrl: 'https://my-app.convex.cloud',
      clientId: 'flutter-app-1.0',
      operationTimeout: Duration(seconds: 30), // Optional, defaults to 30s
      healthCheckQuery: 'health:ping', // Optional, for connection checks (requires health.ts)
    ),
  );

  runApp(MyApp());
}

// Access the client anywhere in your app
void example() async {
  final client = ConvexClient.instance;

  // Optional: authenticate (see Authentication section below)
  await client.setAuth(token: 'YOUR_AUTH_TOKEN');

  // Query (with timeout)
  try {
    final users = await client.query('users:list', {'limit': '10'});
    print('Users: $users');
  } on TimeoutException {
    print('Connection timeout!');
  }

  // Subscribe to real-time updates
  final sub = await client.subscribe(
    name: 'messages:list',
    args: {},
    onUpdate: (value) => print('Update: $value'),
    onError: (message, value) => print('Error: $message ${value ?? ''}'),
  );

  // Mutation
  await client.mutation(
    name: 'messages:send',
    args: {'body': 'Hello!', 'author': 'User123'},
  );

  // Action (if you have actions defined)
  // final res = await client.action(name: 'files:upload', args: {...});

  // Later, when done
  sub.cancel();
}
```

## Authentication

The SDK provides comprehensive authentication support for Convex backends.

### Simple Token Authentication

For basic scenarios or testing, set a static JWT token:

```dart
// Set authentication
await client.setAuth(token: 'your-jwt-token');

// Clear authentication
await client.setAuth(token: null);
```

### Automatic Token Refresh (Recommended)

For production apps, use `setAuthWithRefresh` which automatically refreshes tokens 60 seconds before they expire:

```dart
final authHandle = await client.setAuthWithRefresh(
  fetchToken: () async {
    // Return JWT from your auth provider (Firebase, Clerk, Auth0, etc.)
    return await FirebaseAuth.instance.currentUser?.getIdToken();
  },
  onAuthChange: (isAuthenticated) {
    print('Auth state: $isAuthenticated');
  },
);

// When signing out, dispose the auth handle
authHandle.dispose();
```

### Auth State Stream

Listen to authentication state changes reactively:

```dart
client.authState.listen((isAuthenticated) {
  setState(() => _isLoggedIn = isAuthenticated);
});
```

### Sync Auth Check

Check current auth state synchronously:

```dart
if (client.isAuthenticated) {
  // User is authenticated
}
```

### Clear Authentication

Clear auth and stop any running token refresh:

```dart
await client.clearAuth();
```

## Connection Management

The SDK provides tools for managing connection state and handling network interruptions.

### Operation Timeouts

All queries, mutations, and actions have configurable timeouts (default: 30 seconds):

```dart
await ConvexClient.initialize(
  ConvexConfig(
    deploymentUrl: 'https://my-app.convex.cloud',
    operationTimeout: Duration(seconds: 45), // Custom timeout
  ),
);

// Operations will throw TimeoutException if they exceed the timeout
try {
  await ConvexClient.instance.query('slowQuery', {});
} on TimeoutException {
  print('Operation timed out!');
}
```

### Real-Time WebSocket Connection State (Recommended)

Monitor WebSocket connection state in real-time using streams. This is the recommended approach for connection monitoring:

```dart
// Listen to connection state changes
ConvexClient.instance.connectionState.listen((state) {
  switch (state) {
    case WebSocketConnectionState.connected:
      print('WebSocket connected!');
      // Update UI, enable features
      break;
    case WebSocketConnectionState.connecting:
      print('WebSocket connecting...');
      // Show loading indicator
      break;
  }
});

// Or use in a StreamBuilder for reactive UI
StreamBuilder<WebSocketConnectionState>(
  stream: ConvexClient.instance.connectionState,
  initialData: ConvexClient.instance.currentConnectionState,
  builder: (context, snapshot) {
    final state = snapshot.data ?? WebSocketConnectionState.connecting;
    final isConnected = state == WebSocketConnectionState.connected;

    return Chip(
      avatar: Icon(isConnected ? Icons.cloud_done : Icons.cloud_sync),
      label: Text(isConnected ? 'Connected' : 'Connecting'),
      backgroundColor: isConnected ? Colors.green : Colors.orange,
    );
  },
)

// Synchronous access to current state
if (ConvexClient.instance.isConnected) {
  // WebSocket is connected
}
```

**Features:**
- Real-time state updates via Stream (no polling needed)
- Automatic state transitions when WebSocket connects/disconnects
- Synchronous getter for immediate state access
- Works across all platforms

**Note:** The WebSocket connection is established lazily when the first operation (query, mutation, subscribe, action) is executed.

**Optional: Auto-Connect on Startup**

To establish the connection immediately when your app starts (recommended for better UX), trigger a lightweight query in your app's initialization. Using a dedicated health check query is the cleanest approach:

**1. Create a health check query in your Convex backend (optional but recommended):**

```typescript
// convex/health.ts
import { query } from "./_generated/server";

export const ping = query({
  args: {},
  handler: async () => {
    return "ok";
  },
});
```

**2. Trigger it on app startup:**

```dart
// In your home screen or app initialization
@override
void initState() {
  super.initState();
  // Trigger connection immediately with health check
  ConvexClient.instance.query('health:ping', {});
}
```

**Alternative:** You can use any existing lightweight query instead of creating a dedicated health check:

```dart
// Use any existing query to trigger connection
ConvexClient.instance.query('users:list', {'limit': '1'});
```

### Manual Connection Check (Deprecated)

For backward compatibility, you can check connection status manually using a health check query:

```dart
// Configure a lightweight query for health checks
await ConvexClient.initialize(
  ConvexConfig(
    deploymentUrl: 'https://my-app.convex.cloud',
    healthCheckQuery: 'health:ping', // Lightweight health check query
  ),
);

// Check connection status (deprecated - use connectionState stream instead)
final status = await ConvexClient.instance.checkConnection();

switch (status) {
  case ConnectionStatus.connected:
    print('Connected!');
  case ConnectionStatus.timeout:
    print('Connection timeout');
  case ConnectionStatus.error:
    print('Connection error');
  case ConnectionStatus.unknown:
    print('Not checked yet');
}
```

### Manual Reconnect

Trigger reconnection attempt manually:

```dart
final connected = await ConvexClient.instance.reconnect();
if (connected) {
  print('Reconnected successfully');
}
```

## Lifecycle Monitoring

Monitor app lifecycle events to handle foreground/background transitions.

### Listen to Lifecycle Events

```dart
ConvexClient.instance.lifecycleEvents.listen((event) {
  print('App lifecycle: $event');

  if (event == AppLifecycleEvent.resumed) {
    // App came to foreground
    // Optionally reconnect or refresh data
    ConvexClient.instance.reconnect();
  }

  if (event == AppLifecycleEvent.paused) {
    // App went to background
    // Optionally pause polling or save state
  }
});
```

### Lifecycle Events

- `AppLifecycleEvent.resumed` - App in foreground
- `AppLifecycleEvent.paused` - App in background
- `AppLifecycleEvent.inactive` - App inactive (e.g., during phone call)
- `AppLifecycleEvent.detached` - App being terminated

## API overview

| Method | Description |
|--------|-------------|
| `ConvexClient.initialize(ConvexConfig)` | Initialize singleton client with configuration |
| `ConvexClient.instance` | Access singleton instance anywhere |
| `query(name, args)` | Execute a query with timeout, returns JSON string |
| `mutation({ name, args })` | Execute a mutation with timeout, returns JSON string |
| `action({ name, args })` | Execute an action with timeout, returns JSON string |
| `subscribe({ name, args, onUpdate, onError })` | Subscribe to real-time updates, returns `SubscriptionHandle` |
| `setAuth({ token })` | Set or clear static auth token |
| `setAuthWithRefresh({ fetchToken, onAuthChange })` | Set auth with automatic token refresh, returns `AuthHandleWrapper` |
| `authState` | Stream of auth state changes (`Stream<bool>`) |
| `isAuthenticated` | Current auth state (sync getter) |
| `clearAuth()` | Clear auth and stop token refresh |
| `connectionState` | Real-time WebSocket connection state stream (`Stream<WebSocketConnectionState>`) |
| `currentConnectionState` | Current connection state (sync getter) |
| `isConnected` | Returns true if WebSocket is connected (sync getter) |
| `checkConnection()` | _(Deprecated)_ Manually check connection status, returns `ConnectionStatus` |
| `reconnect()` | Manually trigger reconnection attempt, returns `bool` |
| `lifecycleEvents` | Stream of app lifecycle events (`Stream<AppLifecycleEvent>`) |
| `dispose()` | Clean up client resources |

See the inline docs in `lib/src/convex_client.dart` for details.

## Example app

An example is provided under `example/`:

```
cd example
flutter run
```

The example demonstrates:
- Real-time chat with subscriptions
- Sending messages with mutations
- Authentication with JWT tokens
- Auth state management
- **WebSocket connection state monitoring** with visual indicators
- Lifecycle event monitoring (shows app state in AppBar)
- Connection screen with real-time state history
- Automatic connection on app startup
- Singleton pattern usage (`ConvexClient.instance`)

## Troubleshooting

### Build Issues

- **Rust not found** (native platforms only):
  - Visit [Rust Getting Started Guide](https://www.rust-lang.org/learn/get-started)
  - Install Rust:
    ```bash
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
    ```
  - Update your PATH (add to `~/.bashrc`, `~/.zshrc`, or equivalent):
    ```bash
    source "$HOME/.cargo/env"
    ```
  - Verify installation:
    ```bash
    rustc --version
    cargo --version
    ```
  - **Note**: Not needed for web platform
- **Android build issues**: Use JDK 11, ensure NDK is installed via Android SDK Manager
- **iOS/macOS**: Run `pod install` inside the `example/ios` or your app's `ios` folder if needed
- **Windows**: Install Visual Studio Build Tools with C++ workload

### Connection Issues

- **macOS stuck in "connecting" state**: Missing network entitlements - see [PLATFORM_CONFIGURATION.md](PLATFORM_CONFIGURATION.md#macos)
- **Android network errors**: Missing INTERNET permission - see [PLATFORM_CONFIGURATION.md](PLATFORM_CONFIGURATION.md#android)
- **WebSocket not connecting**: Check your `deploymentUrl` and network permissions
- **Timeout errors**: Increase `operationTimeout` in `ConvexConfig`

**📖 For detailed troubleshooting, see [PLATFORM_CONFIGURATION.md](PLATFORM_CONFIGURATION.md#troubleshooting)**

## Contributing

Contributions are welcome! Please open an issue or pull request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 3.0.1

### Bug Fixes

- **Fixed argument types from `Map<String, String>` to `Map<String, dynamic>`** across all operations (query, mutation, action, subscribe)
  - Nested objects (e.g., `paginationOpts`), arrays, numbers, and booleans are now properly supported as argument values
  - Fix applied consistently across public API, interface, native, and web implementations
  - Removed `toString()` conversion in mutation and action that silently destroyed nested argument structures
  - Closes #15

## 3.0.0

### Major New Features

- **🌐 Web Platform Support**: Full web platform support with pure Dart implementation
  - Uses native browser WebSocket API (no FFI required)
  - 100% API compatibility with native platforms
  - Automatic platform selection via conditional imports
  - No Rust toolchain required for web builds
  - All features work identically on web: queries, mutations, actions, subscriptions, auth

### Web Implementation Details

- Implemented Convex WebSocket wire protocol in pure Dart:
  - RFC 4122 compliant UUID v4 generation for session IDs
  - Proper protocol message formatting (Connect, ModifyQuerySet, Mutation, Action, Transition, Ping/Pong)
  - Query set version tracking with baseVersion/newVersion
  - Integer requestId (u32) for protocol compliance
  - Real-time subscription management with automatic cleanup
  - Connection state monitoring and automatic reconnection
  - Ping/Pong heartbeat for connection keepalive

### Critical Bug Fixes

- **Fixed macOS native platform connection issues**:
  - Root cause: Missing network entitlements in App Sandbox configuration
  - Added `com.apple.security.network.client` to both DebugProfile.entitlements and Release.entitlements
  - macOS apps can now establish WebSocket connections to Convex backend

- **Fixed Android missing INTERNET permission**:
  - Added `<uses-permission android:name="android.permission.INTERNET" />` to AndroidManifest.xml
  - Android apps now have proper network access

- **Fixed Rust rustls CryptoProvider error**:
  - Removed `default-features = false` from convex dependency in Cargo.toml
  - rustls 0.23+ now has proper CryptoProvider configuration

### Improvements

- **Platform Configuration Documentation**:
  - New PLATFORM_CONFIGURATION.md guide with setup instructions for all platforms
  - Updated README.md with platform-specific requirements
  - Clear troubleshooting guides for common connection issues

- **Example App**:
  - All platforms (web, iOS, Android, macOS) now properly configured
  - Works on web without Rust toolchain
  - Demonstrates cross-platform compatibility

- **Rust SDK Update**:
  - Upgraded convex SDK from 0.9.0 to 0.10.2
  - Better protocol compatibility with Convex backend

### Platform Support Matrix

| Platform | Status | Implementation | Network Config Required |
|----------|--------|----------------|-------------------------|
| Web | ✅ New | Pure Dart | None |
| iOS | ✅ Working | FFI + Rust | None |
| macOS | ✅ Fixed | FFI + Rust | Network entitlements |
| Android | ✅ Fixed | FFI + Rust | INTERNET permission |
| Windows | ✅ Working | FFI + Rust | None |
| Linux | ✅ Working | FFI + Rust | None |

### API Changes

None - 100% backward compatible. The same API works across all platforms.

### Breaking Changes

None - this is a feature release with bug fixes, no breaking changes to existing API.

### New Files

- `lib/src/impl/convex_client_web.dart` - Pure Dart WebSocket implementation for web
- `lib/src/impl/convex_client_native.dart` - FFI implementation for native platforms (refactored)
- `PLATFORM_CONFIGURATION.md` - Comprehensive platform setup guide
- `WEB_SUCCESS.md` - Web implementation verification documentation
- `NATIVE_PLATFORM_FIX.md` - Native platform fixes documentation

### Modified Files

- `example/macos/Runner/DebugProfile.entitlements` - Added network permissions
- `example/macos/Runner/Release.entitlements` - Added network permissions
- `example/android/app/src/main/AndroidManifest.xml` - Added INTERNET permission
- `rust/Cargo.toml` - Updated convex SDK and removed default-features = false
- `lib/src/convex_client.dart` - Refactored to use platform-specific implementations
- `README.md` - Added web platform documentation and platform configuration guide

### Migration Guide

No migration needed - existing code works without changes on all platforms including web.

To build for web:
```bash
flutter build web
```

No Rust toolchain required for web builds!

### Known Issues

None - all platforms tested and working.

---

## 1.0.2

- Added support for Dart 3.7.0
- Added support for Flutter 3.3.0
- Added support for Flutter 3.10.0
- Added support for Flutter 3.11.0
- Added support for Flutter 3.12.0
- Added support for Flutter 3.13.0
- Added support for Flutter 3.14.0

## 1.0.3

- Updated flutter_rust_bridge package to 2.9.0

## 1.0.4

- Updated flutter_rust_bridge package to 2.10.0

## 1.2.0

 - Package version updated

## 2.0.0

- Replaced ArcSubscriptionHandle with SubscriptionHandle

## 2.1.0

### New Features

- **Singleton Pattern**: New `ConvexClient.initialize(ConvexConfig)` method with `ConvexClient.instance` access
- **Operation Timeouts**: Configurable timeout for all queries, mutations, and actions (default: 30 seconds)
- **Connection Management**: Manual connection checking with `checkConnection()` and `reconnect()` methods
- **Lifecycle Monitoring**: Stream of app lifecycle events (resumed, paused, inactive, detached)
- **Configuration Class**: New `ConvexConfig` class for cleaner initialization

### Bug Fixes

- Fixed critical Rust subscription panic when WebSocket connection closes unexpectedly
- Subscription streams now exit gracefully instead of crashing the app

### Improvements

- Better error handling for connection issues with `ConnectionStatus` enum
- App lifecycle integration with `AppLifecycleObserver`
- Comprehensive documentation updates with new usage examples
- Example app updated to demonstrate new features

### API Changes

- **Deprecated**: `ConvexClient.init()` is now deprecated, use `ConvexClient.initialize(ConvexConfig)` instead
- **New**: `ConvexClient.instance` - Access singleton anywhere
- **New**: `ConvexClient.initialize(ConvexConfig)` - Initialize with configuration
- **New**: `checkConnection()` - Manual connection status check
- **New**: `reconnect()` - Manual reconnection attempt
- **New**: `lifecycleEvents` stream - Monitor app lifecycle
- **Enhanced**: All queries, mutations, and actions now respect `operationTimeout`

### Breaking Changes

None - backward compatibility maintained through deprecated methods

## 2.2.0

### New Features

- **Real-Time WebSocket Connection State**: Monitor WebSocket connection status via reactive streams
  - `connectionState` stream - Real-time connection state updates (Connected/Connecting)
  - `currentConnectionState` getter - Synchronous access to current state
  - `isConnected` getter - Quick boolean check for connection status
  - Automatic state transitions when WebSocket connects/disconnects
  - No polling required - pure event-driven updates

### Bug Fixes

- **Fixed critical race condition in WebSocket connection initialization**
  - Issue: State change callback was registered after WebSocket connection began, causing state transitions to be lost
  - Root cause: Async task spawning in `connected_client()` created unpredictable timing delays
  - Solution: Removed task spawning and build ConvexClient directly in async context
  - Result: Callback is now guaranteed to be registered before `builder.build()` is called

- **Fixed WebSocket connection state stuck on "connecting"**
  - Issue: Example app showed "connecting" forever without transitioning to "connected"
  - Root cause: No operations were triggered on app startup, so `connected_client()` was never called
  - Solution: Added auto-connection trigger in example app's HomeScreen initialization
  - Result: Connection establishes automatically on startup with proper state transitions

### Improvements

- Enhanced example app with comprehensive WebSocket connection state demonstrations:
  - Connection status indicator in app bar with real-time visual feedback
  - Dedicated Connection screen showing current state and history
  - Automatic connection on app startup
  - All 5 screens demonstrating different SDK capabilities
  - Added HEALTH_CHECK.md guide for setting up health check queries

- Documentation improvements:
  - Comprehensive WebSocket connection state usage examples
  - Recommended health check query pattern using `health:ping`
  - TypeScript example for creating health check query in Convex backend
  - Updated all examples to use dedicated health check instead of `messages:list`
  - Deprecated `checkConnection()` in favor of real-time `connectionState` stream

- Code quality:
  - Comprehensive debug logging for troubleshooting connection issues
  - Better error handling in auto-connection flow
  - Clearer comments explaining lazy initialization

### API Changes

- **New**: `connectionState` stream - Real-time WebSocket connection state updates (`Stream<WebSocketConnectionState>`)
- **New**: `currentConnectionState` getter - Synchronous access to current connection state
- **New**: `isConnected` getter - Boolean check for WebSocket connection status
- **Deprecated**: `checkConnection()` - Use `connectionState` stream for real-time monitoring instead

### Breaking Changes

None - all changes are additive and maintain backward compatibility
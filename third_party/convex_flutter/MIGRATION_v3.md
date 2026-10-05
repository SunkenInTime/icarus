# Migration Guide: v2.x → v3.0.0

## Overview

**Good news: v3.0.0 has ZERO breaking changes!** 🎉

This is a feature release that adds web platform support while maintaining 100% backward compatibility with v2.x. Your existing code will continue to work without modifications.

## What's New in v3.0.0

### Major New Features

1. **Web Platform Support** 🌐
   - Full web platform support with pure Dart implementation
   - No Rust required for web builds
   - Same API works on web and native platforms

2. **Platform-Specific Implementations**
   - Automatic platform selection via conditional imports
   - Web: Pure Dart WebSocket client
   - Native: FFI + Rust SDK (unchanged)

3. **Critical Bug Fixes**
   - Fixed macOS connection issues (network entitlements)
   - Fixed Android missing INTERNET permission
   - Fixed Rust rustls CryptoProvider error

## Migration Steps

### Step 1: Update Package Version

Update your `pubspec.yaml`:

```yaml
dependencies:
  convex_flutter: ^3.0.0  # Update from ^2.2.0
```

Then run:

```bash
flutter pub upgrade convex_flutter
```

### Step 2: Platform Configuration (One-Time Setup)

#### macOS Apps

Add network entitlements to **both** files:

**macos/Runner/DebugProfile.entitlements**:
```xml
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.network.server</key>
<true/>
```

**macos/Runner/Release.entitlements**:
```xml
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.network.server</key>
<true/>
```

#### Android Apps

Add internet permission to **android/app/src/main/AndroidManifest.xml**:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET" />
    <application
        ...
    </application>
</manifest>
```

#### iOS, Windows, Linux Apps

No changes required - these platforms work out of the box.

### Step 3: Test Your App

```bash
# Test on your target platforms
flutter run -d chrome      # Web
flutter run -d macos        # macOS
flutter run -d android      # Android
flutter run -d ios          # iOS
```

### Step 4: Build for Web (New!)

You can now build your app for web:

```bash
flutter build web
```

**No Rust toolchain required for web builds!**

---

## Code Changes Required

### None! ✅

Your existing v2.x code will continue to work without modifications. The API is 100% compatible.

**Example - This code works identically in v2.x and v3.0.0**:

```dart
import 'package:convex_flutter/convex_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialization - no changes
  await ConvexClient.initialize(
    ConvexConfig(
      deploymentUrl: 'https://my-app.convex.cloud',
      clientId: 'flutter-app-1.0',
    ),
  );

  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final client = ConvexClient.instance;

    return MaterialApp(
      home: Scaffold(
        body: StreamBuilder<WebSocketConnectionState>(
          stream: client.connectionState,
          builder: (context, snapshot) {
            // Works on both web and native!
            final isConnected = snapshot.data == WebSocketConnectionState.connected;
            return Text(isConnected ? 'Connected' : 'Connecting...');
          },
        ),
      ),
    );
  }
}
```

---

## Platform-Specific Differences

### Web vs Native

While the API is identical, there are minor implementation differences:

| Feature | Web | Native |
|---------|-----|--------|
| WebSocket Source | Browser WebSocket API | Convex Rust SDK |
| Implementation | Pure Dart | FFI + Rust |
| Build Requirements | None | Rust toolchain |
| Performance | Excellent | Excellent |
| API | **Identical** | **Identical** |

**Bottom Line**: Your code doesn't need to know which platform it's running on. The package handles it automatically.

---

## Deprecations

No APIs were deprecated in v3.0.0. All v2.x methods remain available.

---

## New Capabilities

### Web Platform Support

You can now target web alongside mobile and desktop:

```bash
# Web (new in v3.0.0)
flutter build web

# Mobile (existing)
flutter build apk
flutter build ios

# Desktop (existing)
flutter build macos
flutter build windows
flutter build linux
```

### Cross-Platform Example App

The example app now works on **all platforms**:

```bash
cd example

# Run on any platform
flutter run -d chrome      # Web
flutter run -d macos        # macOS
flutter run -d ios          # iOS Simulator
flutter run -d android      # Android Emulator
flutter run -d windows      # Windows
flutter run -d linux        # Linux
```

---

## Troubleshooting

### macOS: Stuck in "Connecting"

**Symptom**: App builds successfully but connection state never changes from "connecting"

**Solution**: Add network entitlements (see Step 2 above)

**Verify**:
```bash
# Check DebugProfile.entitlements contains:
grep "network.client" macos/Runner/DebugProfile.entitlements
```

### Android: Network Security Exception

**Symptom**: App crashes with `SocketException: Permission denied`

**Solution**: Add INTERNET permission (see Step 2 above)

**Verify**:
```bash
# Check AndroidManifest.xml contains:
grep "INTERNET" android/app/src/main/AndroidManifest.xml
```

### Web: Build Errors

**Symptom**: Build fails when targeting web

**Solution**: Ensure Flutter web support is enabled:

```bash
flutter config --enable-web
flutter clean
flutter pub get
flutter build web
```

### Rust CryptoProvider Error

**Symptom**: `Could not automatically determine the process-level CryptoProvider`

**Solution**: This was fixed in the package. Upgrade to v3.0.0:

```bash
flutter pub upgrade convex_flutter
```

---

## Performance Considerations

### Build Times

**Web**: Faster builds (no Rust compilation)
```bash
# First build
flutter build web  # ~1-2 minutes

# Subsequent builds
flutter build web  # ~30-60 seconds
```

**Native**: Unchanged from v2.x
```bash
# First build (includes Rust compilation)
flutter build apk  # ~3-5 minutes

# Subsequent builds (Rust cached)
flutter build apk  # ~1-2 minutes
```

### Runtime Performance

Both web and native implementations have excellent performance:

- **Web**: Leverages browser's native WebSocket engine
- **Native**: Uses compiled Rust code

**No performance degradation** compared to v2.x.

---

## Testing Recommendations

### Minimum Testing

Before deploying v3.0.0, test on:

- [ ] Your primary target platform (web, iOS, Android, etc.)
- [ ] Connection establishment
- [ ] Query execution
- [ ] Mutation execution
- [ ] Subscriptions (if you use them)
- [ ] Authentication (if you use it)

### Comprehensive Testing

For production apps, also test:

- [ ] Connection state monitoring
- [ ] Reconnection after network interruption
- [ ] App backgrounding/foregrounding
- [ ] Hot reload (development)
- [ ] Release builds

---

## Rollback Plan

If you encounter issues with v3.0.0, you can easily rollback:

```yaml
# pubspec.yaml
dependencies:
  convex_flutter: ^2.2.0  # Rollback to v2.2.0
```

Then run:

```bash
flutter pub downgrade convex_flutter
flutter clean
flutter pub get
```

**Note**: You'll lose web platform support and the bug fixes when rolling back.

---

## Support

If you encounter migration issues:

1. **Check Documentation**:
   - [PLATFORM_CONFIGURATION.md](PLATFORM_CONFIGURATION.md) - Platform setup guide
   - [README.md](README.md) - Updated with v3.0.0 features
   - [ARCHITECTURE.md](ARCHITECTURE.md) - Web implementation details

2. **Search Issues**: https://github.com/jkuldev/convex_flutter/issues

3. **Create New Issue**: https://github.com/jkuldev/convex_flutter/issues/new
   - Include Flutter version, platform, and error details

---

## Changelog

For complete v3.0.0 changes, see [CHANGELOG.md](CHANGELOG.md#300).

**Summary**:
- ✅ Web platform support (pure Dart)
- ✅ Fixed macOS network permissions
- ✅ Fixed Android INTERNET permission
- ✅ Fixed Rust rustls CryptoProvider
- ✅ Updated Convex SDK to 0.10.2
- ✅ Zero breaking changes

---

## Next Steps

After migrating to v3.0.0:

1. **Enable Web** (optional):
   ```bash
   flutter config --enable-web
   flutter run -d chrome
   ```

2. **Review New Documentation**:
   - Platform-specific setup in PLATFORM_CONFIGURATION.md
   - Web implementation details in ARCHITECTURE.md

3. **Enjoy Multi-Platform Support**: Build your Convex Flutter app for web, mobile, and desktop!

---

**Migration Difficulty**: ⭐ Very Easy (no code changes required)

**Time Required**: 5-10 minutes (mostly platform configuration)

**Risk Level**: 🟢 Low (backward compatible, easy rollback)

---

**Questions?** Open an issue: https://github.com/jkuldev/convex_flutter/issues

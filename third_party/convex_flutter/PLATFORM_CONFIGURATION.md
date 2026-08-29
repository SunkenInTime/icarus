# Platform Configuration Guide

This guide explains the platform-specific configuration required for `convex_flutter` to work correctly on all supported platforms.

## Quick Reference

| Platform | Configuration Required | Auto-configured? |
|----------|----------------------|------------------|
| **Web** | None | ✅ Yes |
| **iOS** | None | ✅ Yes |
| **macOS** | Network entitlements | ❌ Manual setup required |
| **Android** | INTERNET permission | ❌ Manual setup required |
| **Windows** | None | ✅ Yes |
| **Linux** | None | ✅ Yes |

---

## Platform-Specific Setup

### macOS

macOS apps use App Sandbox for security, which requires explicit network permissions.

#### Required Files

1. **DebugProfile.entitlements** (for debug builds)
2. **Release.entitlements** (for release builds)

**Location**: `macos/Runner/`

#### Configuration

Add the following entitlements to **both** files:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
</plist>
```

#### Critical Permissions

- `com.apple.security.network.client` - **Required** for outgoing WebSocket connections to Convex
- `com.apple.security.network.server` - **Required** for accepting incoming connections (if needed)
- `com.apple.security.app-sandbox` - Enables macOS App Sandbox
- `com.apple.security.cs.allow-jit` - Allows JIT compilation (required for Flutter)

#### What Happens Without These?

Without `com.apple.security.network.client`, your app will:
- Build and launch successfully
- Get stuck in "connecting" state forever
- Never establish WebSocket connection to Convex
- Show no error messages (silently blocked by macOS sandbox)

---

### Android

Android requires explicit permission for internet access.

#### Required File

**AndroidManifest.xml**

**Location**: `android/app/src/main/AndroidManifest.xml`

#### Configuration

Add the INTERNET permission **inside the `<manifest>` tag, before `<application>`**:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET" />
    <application
        ...
    </application>
</manifest>
```

#### Permission Details

- **Type**: Normal permission (auto-granted at install)
- **User prompt**: No - granted automatically
- **Required for**: All network operations (WebSocket, HTTP, etc.)

#### What Happens Without This?

Without `android.permission.INTERNET`, your app will:
- Build successfully
- Crash or fail when attempting network connections
- Show security exceptions in logs

---

### iOS

**No configuration required** ✅

iOS apps have network access by default unless explicitly restricted. `convex_flutter` works out of the box on iOS.

**Note**: If you're using App Transport Security (ATS) customization, ensure your Convex backend URL is allowed.

---

### Web

**No configuration required** ✅

Web platform uses the browser's native WebSocket API, which inherits the browser's network permissions. Works automatically.

**Technical Details**:
- Uses pure Dart implementation (no FFI)
- Leverages `package:web` for WebSocket access
- Respects browser CORS and security policies

---

### Windows

**No configuration required** ✅

Windows desktop apps have network access by default. The Windows Firewall may prompt users to allow network access on first run (standard Windows behavior).

---

### Linux

**No configuration required** ✅

Linux desktop apps have network access by default. No special permissions or configuration needed.

---

## Troubleshooting

### macOS: Stuck in "Connecting" State

**Symptoms**:
- App builds and launches
- Connection state shows "connecting" forever
- No error messages

**Solution**:
1. Check `macos/Runner/DebugProfile.entitlements`
2. Ensure `com.apple.security.network.client` is present
3. Check `macos/Runner/Release.entitlements` for release builds
4. Clean build: `flutter clean && flutter run`

### Android: Network Security Exception

**Symptoms**:
- App crashes on connection attempt
- Error: `java.net.SocketException: Permission denied`
- Logs show security policy violation

**Solution**:
1. Check `android/app/src/main/AndroidManifest.xml`
2. Add `<uses-permission android:name="android.permission.INTERNET" />`
3. Rebuild: `flutter clean && flutter run`

### Rust Panic: CryptoProvider Error

**Symptoms**:
- Error: `Could not automatically determine the process-level CryptoProvider`
- Panic in rustls library

**Solution**:
This affects the package itself, not user apps. If you encounter this:
1. Check `rust/Cargo.toml`
2. Ensure convex dependency does NOT have `default-features = false`
3. Correct format: `convex = { version = "0.10", features = ["rustls-tls-webpki-roots"] }`

---

## Integration Checklist

When integrating `convex_flutter` into your Flutter app, verify:

- [ ] **macOS**: Added network entitlements to both DebugProfile and Release entitlements
- [ ] **Android**: Added INTERNET permission to AndroidManifest.xml
- [ ] **iOS**: No action required (works by default)
- [ ] **Web**: No action required (works by default)
- [ ] **Windows**: No action required (works by default)
- [ ] **Linux**: No action required (works by default)

---

## Why These Permissions Are Needed

### macOS App Sandbox

macOS uses a security feature called "App Sandbox" that restricts app capabilities by default. Apps must explicitly declare what they need to access (network, files, camera, etc.). This is a macOS platform requirement, not specific to `convex_flutter`.

**Learn more**: [Apple: App Sandbox](https://developer.apple.com/documentation/security/app_sandbox)

### Android Permission System

Android uses a permission-based security model where apps must declare all permissions they'll use. Network access is considered a "normal" permission (auto-granted) but must still be declared in the manifest.

**Learn more**: [Android: App Permissions](https://developer.android.com/guide/topics/permissions/overview)

---

## Example Apps

The `example/` directory in this repository demonstrates proper configuration for all platforms:

```
example/
├── android/app/src/main/AndroidManifest.xml  # INTERNET permission
├── ios/                                       # No config needed
├── macos/Runner/
│   ├── DebugProfile.entitlements             # Network entitlements
│   └── Release.entitlements                  # Network entitlements
├── web/                                       # No config needed
├── windows/                                   # No config needed
└── linux/                                     # No config needed
```

---

## Platform Support Matrix

| Platform | SDK Version | Network Config | Rust Required |
|----------|-------------|----------------|---------------|
| Web | Any | None | No |
| iOS | iOS 12+ | None | Yes (build-time) |
| macOS | macOS 10.14+ | Entitlements | Yes (build-time) |
| Android | API 21+ | Manifest | Yes (build-time) |
| Windows | Windows 7+ | None | Yes (build-time) |
| Linux | Any | None | Yes (build-time) |

**Note**: Rust is required at **build time** for native platforms (iOS, macOS, Android, Windows, Linux) but **not required** for web platform.

---

## Questions or Issues?

If you encounter platform-specific issues not covered here:

1. Check the [example app configuration](example/)
2. Search [GitHub issues](https://github.com/get-convex/convex_flutter/issues)
3. Create a new issue with:
   - Platform and version
   - Flutter doctor output
   - Relevant configuration files
   - Error messages or logs

---

**Last Updated**: 2026-01-10
**Package Version**: 3.0.0

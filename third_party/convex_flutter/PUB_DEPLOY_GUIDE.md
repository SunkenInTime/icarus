# Pub.dev Deployment Guide - convex_flutter v2.2.0

## Pre-Deployment Checklist

### ✅ All Requirements Met

- [x] Version bumped to 2.2.0 in pubspec.yaml
- [x] CHANGELOG.md updated with detailed v2.2.0 release notes
- [x] README.md updated with all new features documented
- [x] LICENSE file present (MIT License)
- [x] Package validation passed (`flutter pub publish --dry-run`)
- [x] All commits pushed to GitHub
- [x] Example app working and demonstrating all features

### Package Information

**Package Name**: `convex_flutter`
**Version**: `2.2.0`
**Repository**: https://github.com/jkuldev/convex_flutter
**Homepage**: https://jkuldev.com
**License**: MIT
**Package Size**: 328 KB (compressed)

## What's New in v2.2.0

### Major Features

1. **Real-Time WebSocket Connection State Monitoring**
   - `connectionState` stream for real-time updates
   - `currentConnectionState` getter for sync access
   - `isConnected` boolean getter
   - Automatic state transitions (Connecting → Connected)

2. **Critical Bug Fixes**
   - Fixed race condition in WebSocket connection initialization
   - Fixed connection state stuck on "connecting"
   - Improved connection reliability

3. **Enhanced Documentation**
   - Health check query setup guide (TypeScript + Dart)
   - Comprehensive usage examples with StreamBuilder
   - Clear optional vs required patterns
   - Step-by-step tutorials

### API Additions

```dart
// New in v2.2.0
Stream<WebSocketConnectionState> connectionState
WebSocketConnectionState currentConnectionState
bool isConnected
```

### Deprecated APIs

```dart
// Deprecated (still works, but use connectionState instead)
Future<ConnectionStatus> checkConnection()
```

## Deployment Steps

### Step 1: Final Validation

Run the dry-run command to verify everything is ready:

```bash
flutter pub publish --dry-run
```

**Expected Output:**
- Package validation passed
- 0 warnings
- 1 hint about version increment (this is fine)
- Total compressed size: ~328 KB

### Step 2: Verify Git Status

Make sure all changes are committed:

```bash
git status
git log --oneline -5
```

**Expected Commits on Branch:**
```
5218369 chore: Bump version to 2.2.0 for pub.dev release
ce51ed4 docs: Clarify health check is optional but recommended
0e7484c docs: Recommend dedicated health check query (health:ping)
8aa9d6e example updated
3c34666 feat: Add real-time WebSocket connection state monitoring (v2.2.0)
```

### Step 3: Push to GitHub

Push the branch to GitHub:

```bash
git push -u origin fix/websocket-connection-state-v2.2.0
```

**Or if using HTTPS:**
```bash
git remote set-url origin https://github.com/jkuldev/convex_flutter.git
git push -u origin fix/websocket-connection-state-v2.2.0
```

### Step 4: Merge to Main

Option A - Via GitHub Pull Request:
1. Go to https://github.com/jkuldev/convex_flutter/pulls
2. Create Pull Request from `fix/websocket-connection-state-v2.2.0`
3. Review changes
4. Merge to main
5. Pull main locally: `git checkout main && git pull`

Option B - Local Merge:
```bash
git checkout main
git merge fix/websocket-connection-state-v2.2.0
git push origin main
```

### Step 5: Create Git Tag (Recommended)

```bash
git tag v2.2.0
git push origin v2.2.0
```

Or create annotated tag with release notes:
```bash
git tag -a v2.2.0 -m "Release v2.2.0: WebSocket Connection State Monitoring

- Real-time WebSocket connection state streams
- Fixed critical race condition in connection initialization
- Fixed connection state stuck on 'connecting'
- Enhanced documentation with health check guide
- New connection state APIs
- Comprehensive example app with 5 screens"

git push origin v2.2.0
```

### Step 6: Publish to pub.dev

**IMPORTANT**: Make sure you're on the main branch with the latest changes:

```bash
git checkout main
git pull
```

**Publish the package:**

```bash
flutter pub publish
```

**The command will:**
1. Validate the package
2. Show a preview of what will be published
3. Ask for confirmation
4. Upload to pub.dev

**You'll need:**
- A verified pub.dev account
- Access credentials (you'll be prompted to login)

**After Publishing:**
- Package will be available at: https://pub.dev/packages/convex_flutter
- Version 2.2.0 will appear within minutes

### Step 7: Verify Publication

After publishing, verify on pub.dev:

1. Visit: https://pub.dev/packages/convex_flutter
2. Check version shows as 2.2.0
3. Verify README displays correctly
4. Check CHANGELOG is visible
5. Confirm example tab shows code
6. Review package score (should be 130+/140)

## Post-Deployment

### Create GitHub Release

1. Go to: https://github.com/jkuldev/convex_flutter/releases/new
2. Choose tag: `v2.2.0`
3. Release title: `v2.2.0 - WebSocket Connection State Monitoring`
4. Description: Copy from CHANGELOG.md or use:

```markdown
## 🎉 convex_flutter v2.2.0

### New Features
- **Real-Time WebSocket Connection State**: Monitor connection status via reactive streams
- `connectionState` stream for real-time updates
- `currentConnectionState` and `isConnected` getters
- Automatic state transitions

### Bug Fixes
- Fixed critical race condition in WebSocket connection initialization
- Fixed connection state stuck on "connecting"
- Improved connection reliability

### Documentation
- Comprehensive health check guide with TypeScript examples
- WebSocket connection state usage examples
- Enhanced example app with 5 demonstration screens

[View Full Changelog](https://github.com/jkuldev/convex_flutter/blob/main/CHANGELOG.md)

**Install:**
```yaml
dependencies:
  convex_flutter: ^2.2.0
```
```

5. Publish release

### Announce (Optional)

Consider announcing the release:
- Twitter/X
- LinkedIn
- Flutter community Discord/Slack
- Reddit r/FlutterDev
- Dev.to blog post

## Troubleshooting

### Issue: "Unauthorized" error when publishing

**Solution:**
```bash
# Login to pub.dev
dart pub login

# Then try publishing again
flutter pub publish
```

### Issue: "Version already exists"

**Solution:**
- Version 2.2.0 is already published
- Increment version to 2.2.1 or 2.3.0
- Update CHANGELOG.md
- Commit and try again

### Issue: Package validation fails

**Solution:**
```bash
# Run dry-run to see specific errors
flutter pub publish --dry-run

# Fix any errors shown
# Common issues:
# - Missing README.md
# - Missing CHANGELOG.md
# - Invalid pubspec.yaml
# - Missing LICENSE
```

### Issue: Git push fails (permission denied)

**Solution:**
```bash
# Use HTTPS instead of SSH
git remote set-url origin https://github.com/jkuldev/convex_flutter.git

# Or set up SSH keys:
ssh-keygen -t ed25519 -C "your_email@example.com"
# Add to GitHub: https://github.com/settings/keys
```

## Rollback Plan

If issues are discovered after publishing:

### Option 1: Publish Hotfix (Recommended)

```bash
# Fix the issue
# Update version to 2.2.1
# Update CHANGELOG.md
git commit -am "fix: Critical issue in v2.2.0"
flutter pub publish
```

### Option 2: Retract Version (Last Resort)

```bash
# This marks the version as broken
dart pub publisher retract convex_flutter 2.2.0
```

**Note:** Retraction doesn't delete the package, it just warns users.

## Support After Release

Monitor for issues:
- GitHub Issues: https://github.com/jkuldev/convex_flutter/issues
- pub.dev comments
- Stack Overflow questions tagged `convex-flutter`

## Success Criteria

✅ Package published successfully
✅ Version 2.2.0 visible on pub.dev
✅ Documentation renders correctly
✅ Example app accessible via pub.dev
✅ Package score 130+/140
✅ GitHub release created with tag v2.2.0
✅ All features working as documented

## Contact

If you encounter any issues during deployment:
- Check pub.dev documentation: https://dart.dev/tools/pub/publishing
- Flutter pub publishing guide: https://flutter.dev/docs/development/packages-and-plugins/developing-packages

---

**Ready to publish!** 🚀

Run: `flutter pub publish`

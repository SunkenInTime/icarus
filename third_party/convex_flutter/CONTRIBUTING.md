# Contributing to convex_flutter

Thank you for your interest in contributing to `convex_flutter`! This document provides guidelines and instructions for contributing to the project.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [How Can I Contribute?](#how-can-i-contribute)
- [Development Setup](#development-setup)
- [Project Structure](#project-structure)
- [Making Changes](#making-changes)
- [Testing](#testing)
- [Submitting Changes](#submitting-changes)
- [Style Guidelines](#style-guidelines)
- [Platform-Specific Contributions](#platform-specific-contributions)

---

## Code of Conduct

This project adheres to a code of conduct that all contributors are expected to follow:

- Be respectful and inclusive
- Welcome newcomers and help them get started
- Focus on constructive criticism
- Respect differing viewpoints and experiences
- Accept responsibility and apologize for mistakes

## How Can I Contribute?

### Reporting Bugs

Before creating bug reports, please check existing issues to avoid duplicates. When creating a bug report, include:

- **Clear title** describing the issue
- **Detailed description** of the problem
- **Steps to reproduce** the behavior
- **Expected vs actual behavior**
- **Environment details**:
  - Flutter version (`flutter --version`)
  - Dart version
  - Platform (Web, Android, iOS, macOS, Windows, Linux)
  - Package version
  - Rust version (for native platforms)
- **Stack traces or error messages**
- **Minimal reproducible example** if possible

**Template**:
```markdown
**Description**: Brief description of the issue

**Steps to Reproduce**:
1. Initialize ConvexClient with...
2. Call query/mutation/subscribe...
3. Observe error...

**Expected**: What should happen
**Actual**: What actually happens

**Environment**:
- Flutter: 3.19.0
- Dart: 3.3.0
- Platform: Web / Android / iOS / etc.
- convex_flutter: 3.0.0
- Rust: 1.75.0 (if applicable)

**Error Output**:
```
[Paste error here]
```

**Additional Context**: Any other relevant information
```

### Suggesting Enhancements

Enhancement suggestions are tracked as GitHub issues. When creating an enhancement suggestion, include:

- **Clear title** describing the enhancement
- **Detailed description** of the proposed feature
- **Use case** explaining why this would be useful
- **Proposed implementation** (if you have ideas)
- **Alternatives considered**

### Pull Requests

We actively welcome pull requests! To contribute code:

1. **Fork** the repository
2. **Create a branch** from `main` (`git checkout -b feature/my-feature`)
3. **Make your changes** following our style guidelines
4. **Test your changes** on relevant platforms
5. **Commit your changes** with clear commit messages
6. **Push to your fork** (`git push origin feature/my-feature`)
7. **Open a Pull Request** with a clear description

---

## Development Setup

### Prerequisites

**For All Contributors**:
- Flutter SDK (>= 3.3.0)
- Dart SDK (>= 3.8.1)
- Git
- A code editor (VS Code, Android Studio, etc.)

**For Native Platform Development**:
- Rust toolchain (`rustup` + `cargo`)
- Platform-specific tools:
  - **Android**: JDK 11, Android SDK, NDK
  - **iOS/macOS**: Xcode, CocoaPods
  - **Windows**: Visual Studio Build Tools (C++)
  - **Linux**: build-essential, clang, pkg-config

**For Web Platform Development**:
- No Rust required!
- Just Flutter and Dart

### Initial Setup

```bash
# 1. Clone your fork
git clone https://github.com/YOUR_USERNAME/convex_flutter.git
cd convex_flutter

# 2. Install Rust (skip if only working on web)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source $HOME/.cargo/env

# 3. Install dependencies
flutter pub get

# 4. Run example app
cd example
flutter pub get
flutter run -d chrome  # For web
# OR
flutter run -d macos   # For native
```

### Setting Up for Development

```bash
# Run flutter_rust_bridge code generation (if modifying Rust code)
cd rust
flutter_rust_bridge_codegen \
  --rust-input src/lib.rs \
  --dart-output ../lib/src/rust/lib.dart

# Format Dart code
dart format .

# Format Rust code
cd rust
cargo fmt

# Analyze Dart code
flutter analyze

# Run tests
flutter test
```

---

## Project Structure

```
convex_flutter/
├── lib/                          # Dart source code
│   ├── convex_flutter.dart       # Public API exports
│   ├── src/
│   │   ├── convex_client.dart    # Main client (platform-agnostic)
│   │   ├── impl/
│   │   │   ├── convex_client_web.dart     # Web implementation (pure Dart)
│   │   │   └── convex_client_native.dart  # Native implementation (FFI)
│   │   ├── rust/                 # Generated FFI bindings
│   │   ├── convex_config.dart    # Configuration class
│   │   ├── connection_status.dart
│   │   ├── app_lifecycle_*.dart
│   │   └── ...                   # Other Dart utilities
│
├── rust/                         # Rust source code (native platforms)
│   ├── Cargo.toml                # Rust dependencies
│   ├── src/
│   │   ├── lib.rs                # Main Rust implementation
│   │   └── frb_generated.rs      # Generated FFI code
│   └── target/                   # Build artifacts
│
├── example/                      # Example Flutter app
│   ├── lib/main.dart             # Example app code
│   ├── android/                  # Android configuration
│   ├── ios/                      # iOS configuration
│   ├── macos/                    # macOS configuration
│   ├── web/                      # Web configuration
│   └── ...
│
├── test/                         # Unit tests
├── ARCHITECTURE.md               # Architecture documentation
├── PLATFORM_CONFIGURATION.md     # Platform setup guide
├── CHANGELOG.md                  # Version history
└── README.md                     # Main documentation
```

---

## Making Changes

### Branching Strategy

- `main` - Stable release branch
- `develop` - Development branch (if used)
- `feature/*` - New features
- `fix/*` - Bug fixes
- `docs/*` - Documentation improvements
- `refactor/*` - Code refactoring

### Commit Messages

Write clear, descriptive commit messages following this format:

```
type(scope): Brief description

Detailed explanation of changes (optional)

Fixes #issue_number (if applicable)
```

**Types**:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style changes (formatting, etc.)
- `refactor`: Code refactoring
- `test`: Adding or updating tests
- `chore`: Maintenance tasks

**Examples**:
```
feat(web): Add web platform support with pure Dart implementation

Implemented Convex WebSocket protocol in pure Dart for web platform.
Includes UUID generation, protocol messages, and subscription handling.

Fixes #123
```

```
fix(macos): Add missing network entitlements

Added com.apple.security.network.client entitlement to fix
WebSocket connection issues on macOS.

Fixes #456
```

---

## Testing

### Running Tests

```bash
# Run all tests
flutter test

# Run specific test file
flutter test test/convex_client_test.dart

# Run tests with coverage
flutter test --coverage
```

### Manual Testing

**Web Platform**:
```bash
cd example
flutter run -d chrome
# Test all features in the browser
```

**Native Platforms**:
```bash
cd example

# macOS
flutter run -d macos

# iOS (requires macOS + Xcode)
flutter run -d ios

# Android (requires Android device/emulator)
flutter run -d android
```

### Test Checklist for Pull Requests

Before submitting a PR, verify:

- [ ] All existing tests pass
- [ ] New features have tests
- [ ] Manual testing completed on relevant platforms:
  - [ ] Web (if web-related changes)
  - [ ] At least one native platform (if native changes)
- [ ] No breaking changes (or clearly documented)
- [ ] Documentation updated (if API changes)
- [ ] CHANGELOG.md updated (for notable changes)

---

## Submitting Changes

### Pull Request Process

1. **Update Documentation**: If you changed APIs, update:
   - README.md
   - Inline code documentation
   - ARCHITECTURE.md (if architectural changes)
   - PLATFORM_CONFIGURATION.md (if platform-specific changes)

2. **Update CHANGELOG.md**: Add entry under "Unreleased" section:
   ```markdown
   ## Unreleased

   ### New Features
   - Your feature description

   ### Bug Fixes
   - Your fix description
   ```

3. **Create Pull Request** with:
   - **Clear title**: `feat: Add web platform support`
   - **Description**: Explain what, why, and how
   - **Issue reference**: `Fixes #123` or `Closes #456`
   - **Screenshots/GIFs**: For UI changes
   - **Testing notes**: How you tested the changes
   - **Breaking changes**: Clearly marked if any

4. **Respond to Reviews**: Address feedback promptly and respectfully

5. **CI/CD Checks**: Ensure all automated checks pass

### PR Template

```markdown
## Description
Brief description of changes

## Type of Change
- [ ] Bug fix (non-breaking change fixing an issue)
- [ ] New feature (non-breaking change adding functionality)
- [ ] Breaking change (fix or feature that breaks existing functionality)
- [ ] Documentation update

## Related Issue
Fixes #(issue number)

## How Has This Been Tested?
Describe testing process

## Platforms Tested
- [ ] Web
- [ ] Android
- [ ] iOS
- [ ] macOS
- [ ] Windows
- [ ] Linux

## Checklist
- [ ] My code follows the project's style guidelines
- [ ] I have performed a self-review
- [ ] I have commented my code where needed
- [ ] I have updated documentation
- [ ] I have added tests
- [ ] All tests pass locally
- [ ] I have updated CHANGELOG.md
```

---

## Style Guidelines

### Dart Code Style

Follow the [Dart Style Guide](https://dart.dev/guides/language/effective-dart/style):

```bash
# Format code
dart format .

# Analyze code
flutter analyze
```

**Key conventions**:
- Use `lowerCamelCase` for variables, methods, parameters
- Use `UpperCamelCase` for classes, enums, typedefs
- Prefer `final` over `var`
- Use trailing commas for better formatting
- Document public APIs with `///` doc comments

**Example**:
```dart
/// Executes a Convex query with the given [name] and [args].
///
/// Returns a JSON string containing the query result.
/// Throws [TimeoutException] if the operation exceeds [operationTimeout].
///
/// Example:
/// ```dart
/// final result = await client.query('users:list', {'limit': '10'});
/// final users = jsonDecode(result);
/// ```
Future<String> query(String name, Map<String, String> args) async {
  // Implementation
}
```

### Rust Code Style

Follow the [Rust Style Guide](https://doc.rust-lang.org/beta/style-guide/):

```bash
cd rust
cargo fmt  # Format
cargo clippy  # Lint
```

**Key conventions**:
- Use `snake_case` for functions, variables
- Use `UpperCamelCase` for types, traits
- Document public items with `///` comments
- Use `Result` for error handling
- Prefer pattern matching over if/else

---

## Platform-Specific Contributions

### Working on Web Platform

**File**: `lib/src/impl/convex_client_web.dart`

**Dependencies**: `package:web`, `package:http`

**No Rust required!**

**Testing**:
```bash
flutter run -d chrome
flutter test  # Tests run on VM, but web code path is used
```

**Key areas**:
- WebSocket protocol implementation
- UUID generation
- Connection state management
- Subscription handling

### Working on Native Platforms

**File**: `rust/src/lib.rs`, `lib/src/impl/convex_client_native.dart`

**Dependencies**: Rust toolchain, `flutter_rust_bridge`

**Testing**: Requires platform-specific setup (Xcode for iOS/macOS, Android SDK for Android, etc.)

**Key areas**:
- FFI bridge between Dart and Rust
- Rust wrapper around Convex SDK
- Native platform configurations (entitlements, permissions)

### Adding New Features

When adding features:

1. **Implement for both platforms** (web + native) if applicable
2. **Maintain API parity** between platforms
3. **Add tests** for both implementations
4. **Update documentation** in README.md
5. **Add platform-specific notes** in PLATFORM_CONFIGURATION.md if needed

---

## Questions?

- **Issues**: https://github.com/jkuldev/convex_flutter/issues
- **Discussions**: https://github.com/jkuldev/convex_flutter/discussions
- **Email**: Contact maintainers at jkuldev.com

---

## License

By contributing to `convex_flutter`, you agree that your contributions will be licensed under the MIT License.

---

**Thank you for contributing to convex_flutter! 🎉**

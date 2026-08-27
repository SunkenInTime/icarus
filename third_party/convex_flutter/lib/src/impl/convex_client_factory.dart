/// Factory for creating platform-specific ConvexClient implementations.
///
/// Uses conditional imports to avoid compiling web-only code on native platforms.
library convex_client_factory;

import 'package:convex_flutter/src/convex_config.dart';
import 'package:convex_flutter/src/impl/convex_client_interface.dart';

// Import appropriate implementation based on platform
import 'convex_client_factory_io.dart'
    if (dart.library.js_interop) 'convex_client_factory_web.dart';

/// Creates the appropriate platform-specific ConvexClient implementation.
///
/// This factory method uses conditional imports to:
/// - Return NativeConvexClient on native platforms (iOS, Android, macOS, Windows, Linux)
/// - Return WebConvexClient on web platform
///
/// This prevents web-only libraries (dart:js_interop, package:web) from being
/// compiled into native builds, which would cause compilation errors.
Future<IConvexClient> createPlatformClient(ConvexConfig config) async {
  return await createClientImpl(config);
}

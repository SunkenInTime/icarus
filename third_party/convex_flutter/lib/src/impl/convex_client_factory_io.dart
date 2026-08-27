/// Native platform (IO) implementation factory.
///
/// This file is imported on iOS, Android, macOS, Windows, and Linux platforms.

import 'package:convex_flutter/src/convex_config.dart';
import 'package:convex_flutter/src/impl/convex_client_interface.dart';
import 'package:convex_flutter/src/impl/convex_client_native.dart';

/// Creates a NativeConvexClient for native platforms.
Future<IConvexClient> createClientImpl(ConvexConfig config) async {
  return await NativeConvexClient.create(config);
}

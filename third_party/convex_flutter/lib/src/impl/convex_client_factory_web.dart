/// Web platform implementation factory.
///
/// This file is imported only on web platform (when dart:js_interop is available).

import 'package:convex_flutter/src/convex_config.dart';
import 'package:convex_flutter/src/impl/convex_client_interface.dart';
import 'package:convex_flutter/src/impl/convex_client_web.dart';

/// Creates a WebConvexClient for web platform.
Future<IConvexClient> createClientImpl(ConvexConfig config) async {
  return await WebConvexClient.create(config);
}

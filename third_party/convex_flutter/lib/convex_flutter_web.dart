/// Web platform implementation of convex_flutter plugin.
///
/// This file is automatically registered by Flutter when building for web.
library convex_flutter_web;

import 'package:flutter_web_plugins/flutter_web_plugins.dart';

/// The web implementation of [ConvexFlutterPlatform].
///
/// This class is automatically registered when building for web.
/// The actual web functionality is provided by [WebConvexClient].
class ConvexFlutterWeb {
  /// Factory constructor for web platform plugin registration.
  static void registerWith(Registrar registrar) {
    // No platform channel needed for web - we use pure Dart WebSocket implementation
    // The ConvexClient automatically selects WebConvexClient when kIsWeb is true
  }
}

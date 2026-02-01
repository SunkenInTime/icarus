import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError(_notConfiguredMessage);
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
        throw UnsupportedError(_notConfiguredMessage);
      case TargetPlatform.fuchsia:
        throw UnsupportedError(_notConfiguredMessage);
    }
  }

  static const String _notConfiguredMessage =
      'Firebase options are not configured. Run "flutterfire config" to '
      'generate firebase_options.dart, then rebuild.';
}

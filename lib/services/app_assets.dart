import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The app's assets for anything that shows what arrives: pictures and data
/// that widgets watch. It sits above the app as the `DefaultAssetBundle`, so
/// `Image.asset` already reads through it.
///
/// On web an asset is a network request, so it can fail. A failure leaves a
/// picture blank with a red error, and nothing asks again when the connection
/// returns. A read here doesn't fail. It waits until the asset arrives, and
/// whatever asked for it fills in by itself.
///
/// Code that needs an answer now must not read through this, because it could
/// wait for as long as the user is offline. A page switch needs its routes or
/// it can't finish, so `navigationGeometryProvider` reads through `rootBundle`
/// and handles the failure.
final WaitingAssetBundle appAssets = WaitingAssetBundle();

class WaitingAssetBundle extends CachingAssetBundle {
  /// Time between tries while an asset can't be read. Short enough that it
  /// comes back on its own moments after the connection does.
  static const retryDelay = Duration(seconds: 3);

  /// Assets whose last try failed and are still being tried.
  final ValueNotifier<Set<String>> missing = ValueNotifier(const {});

  final Map<String, Future<ByteData>> _loading = {};

  @override
  Future<ByteData> load(String key) {
    return _loading[key] ??=
        _untilItArrives(key, rootBundle.load).whenComplete(() {
      _loading.remove(key);
    });
  }

  /// `rootBundle`'s own read, which on desktop skips copying the file through
  /// the platform channel. Images ask for this one.
  @override
  Future<ui.ImmutableBuffer> loadBuffer(String key) =>
      _untilItArrives(key, rootBundle.loadBuffer);

  Future<T> _untilItArrives<T>(
    String key,
    Future<T> Function(String key) read,
  ) async {
    while (true) {
      try {
        final result = await read(key);
        if (missing.value.contains(key)) {
          missing.value = {...missing.value}..remove(key);
        }
        return result;
      } catch (error) {
        if (!missing.value.contains(key)) {
          debugPrint('Waiting for asset $key: $error');
          missing.value = {...missing.value, key};
        }
        await Future<void>.delayed(retryDelay);
      }
    }
  }
}

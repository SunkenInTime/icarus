import 'package:flutter/widgets.dart';
import 'package:convex_flutter/src/app_lifecycle_event.dart';

/// Observes Flutter app lifecycle state changes and emits events.
///
/// This class uses Flutter's WidgetsBindingObserver to monitor
/// when the app transitions between foreground, background, and
/// other lifecycle states.
///
/// The observer automatically registers itself with WidgetsBinding
/// upon creation and should be disposed when no longer needed.
class AppLifecycleObserver with WidgetsBindingObserver {
  /// Callback function invoked when app lifecycle state changes
  final void Function(AppLifecycleEvent) onLifecycleChange;

  /// Creates a new lifecycle observer with the specified callback.
  ///
  /// The observer automatically registers itself with WidgetsBinding.
  AppLifecycleObserver({required this.onLifecycleChange}) {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final event = switch (state) {
      AppLifecycleState.resumed => AppLifecycleEvent.resumed,
      AppLifecycleState.paused => AppLifecycleEvent.paused,
      AppLifecycleState.inactive => AppLifecycleEvent.inactive,
      AppLifecycleState.detached => AppLifecycleEvent.detached,
      _ => null,
    };

    if (event != null) {
      onLifecycleChange(event);
    }
  }

  /// Disposes the observer and unregisters it from WidgetsBinding.
  ///
  /// Call this method when the observer is no longer needed to prevent
  /// memory leaks.
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }
}

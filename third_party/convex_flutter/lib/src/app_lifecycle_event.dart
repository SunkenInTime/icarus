/// Enum representing Flutter app lifecycle state changes.
///
/// These events are emitted by the ConvexClient when the app
/// transitions between different lifecycle states.
///
/// Example usage:
/// ```dart
/// ConvexClient.instance.lifecycleEvents.listen((event) {
///   if (event == AppLifecycleEvent.resumed) {
///     print('App came to foreground');
///   }
/// });
/// ```
enum AppLifecycleEvent {
  /// App has come to the foreground and is visible to the user
  resumed,

  /// App is in the background but still running
  paused,

  /// App is inactive (e.g., during a phone call or system dialog)
  inactive,

  /// App is being terminated
  detached,
}

/// Configuration for ConvexClient initialization.
///
/// This class holds all configuration options for initializing
/// the Convex client singleton.
///
/// Example usage:
/// ```dart
/// await ConvexClient.initialize(
///   ConvexConfig(
///     deploymentUrl: "https://your-app.convex.cloud",
///     clientId: "flutter-app",
///     operationTimeout: Duration(seconds: 30),
///     healthCheckQuery: "system:ping",
///   ),
/// );
/// ```
class ConvexConfig {
  /// The URL of your Convex deployment.
  ///
  /// Example: "https://my-app.convex.cloud"
  final String deploymentUrl;

  /// Optional unique identifier for this client instance.
  ///
  /// If not provided, defaults to 'flutter-client'.
  final String? clientId;

  /// Timeout duration for all query, mutation, and action operations.
  ///
  /// Operations that take longer than this duration will throw
  /// a TimeoutException. Defaults to 30 seconds.
  final Duration operationTimeout;

  /// Optional query name to use for manual connection health checks.
  ///
  /// This should be the name of a lightweight query in your Convex backend
  /// that can be used to verify the connection is working.
  ///
  /// Example: "system:ping" or any query that returns quickly.
  ///
  /// If null, calling `ConvexClient.instance.checkConnection()` will throw
  /// a StateError. You can still check connection by attempting regular
  /// queries and catching TimeoutException.
  final String? healthCheckQuery;

  /// Creates a new ConvexConfig with the specified options.
  const ConvexConfig({
    required this.deploymentUrl,
    this.clientId,
    this.operationTimeout = const Duration(seconds: 30),
    this.healthCheckQuery,
  });
}

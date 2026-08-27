/// Enum representing the possible connection states when checking
/// connectivity to the Convex backend.
enum ConnectionStatus {
  /// Connection check has not been performed yet
  unknown,

  /// Successfully connected to the backend
  connected,

  /// Connection check timed out
  timeout,

  /// An error occurred during the connection check
  error,
}

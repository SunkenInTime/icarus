class ConvexConfig {
  const ConvexConfig({
    required this.deploymentUrl,
    required this.clientId,
    this.operationTimeout = const Duration(seconds: 30),
    this.healthCheckQuery,
  });

  final String deploymentUrl;
  final String clientId;
  final Duration operationTimeout;
  final String? healthCheckQuery;
}

enum WebSocketConnectionState {
  connecting,
  connected,
}

abstract interface class SubscriptionHandle {
  void cancel();
}

abstract interface class AuthHandleWrapper {
  void dispose();
}

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

final class ConvexClientFunctionError implements Exception {
  const ConvexClientFunctionError({
    required this.rawCode,
    required this.message,
    required this.data,
  });

  final String rawCode;
  final String message;
  final Object? data;

  @override
  String toString() => 'ConvexClientFunctionError($rawCode, $message)';
}

abstract interface class ConvexClientValueSource {
  Future<Object?> queryValue(String name, Map<String, Object?> args);

  Future<Object?> mutationValue({
    required String name,
    required Map<String, Object?> args,
  });

  Future<Object?> actionValue({
    required String name,
    required Map<String, Object?> args,
  });

  Future<SubscriptionHandle> subscribeValue({
    required String name,
    required Map<String, Object?> args,
    required void Function(Object? value) onUpdate,
    required void Function(ConvexClientFunctionError error) onError,
  });
}

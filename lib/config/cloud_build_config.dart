const String developmentConvexDeploymentUrl =
    'https://majestic-eel-413.convex.cloud';
const String developmentConvexClientId = 'dev:majestic-eel-413';
const String _developmentConvexHost = 'majestic-eel-413.convex.cloud';

const String _compiledCloudEnvironment = String.fromEnvironment(
  'ICARUS_CLOUD_ENVIRONMENT',
);
const String _compiledConvexDeploymentUrl = String.fromEnvironment(
  'ICARUS_CONVEX_DEPLOYMENT_URL',
);
const String _compiledConvexClientId = String.fromEnvironment(
  'ICARUS_CONVEX_CLIENT_ID',
);

class CloudBuildConfig {
  const CloudBuildConfig._({
    required this.environment,
    required this.deploymentUrl,
    required this.clientId,
  });

  final String environment;
  final String deploymentUrl;
  final String clientId;

  factory CloudBuildConfig.fromEnvironment({required bool isReleaseMode}) {
    return CloudBuildConfig.forBuild(
      isReleaseMode: isReleaseMode,
      environment: _compiledCloudEnvironment,
      deploymentUrl: _compiledConvexDeploymentUrl,
      clientId: _compiledConvexClientId,
    );
  }

  factory CloudBuildConfig.forBuild({
    required bool isReleaseMode,
    String environment = '',
    String deploymentUrl = '',
    String clientId = '',
  }) {
    if (environment.trim().isEmpty) {
      if (isReleaseMode) {
        throw StateError(
          'Release builds require an explicit ICARUS_CLOUD_ENVIRONMENT. '
          "Use 'development' for CI or prerelease, or 'production' with "
          'production Convex values.',
        );
      }
      environment = 'development';
    }

    return CloudBuildConfig.resolve(
      environment: environment,
      deploymentUrl: deploymentUrl,
      clientId: clientId,
    );
  }

  factory CloudBuildConfig.resolve({
    required String environment,
    String deploymentUrl = '',
    String clientId = '',
  }) {
    final resolvedEnvironment = environment.trim().toLowerCase();
    final resolvedDeploymentUrl = deploymentUrl.trim();
    final resolvedClientId = clientId.trim();

    switch (resolvedEnvironment) {
      case 'development':
        if (resolvedDeploymentUrl.isEmpty != resolvedClientId.isEmpty) {
          throw StateError(
            'Development Convex overrides must include both '
            'ICARUS_CONVEX_DEPLOYMENT_URL and ICARUS_CONVEX_CLIENT_ID.',
          );
        }

        final developmentUrl = resolvedDeploymentUrl.isEmpty
            ? developmentConvexDeploymentUrl
            : resolvedDeploymentUrl;
        _requireHttpsUrl(developmentUrl);
        return CloudBuildConfig._(
          environment: resolvedEnvironment,
          deploymentUrl: developmentUrl,
          clientId: resolvedClientId.isEmpty
              ? developmentConvexClientId
              : resolvedClientId,
        );
      case 'production':
        if (resolvedDeploymentUrl.isEmpty || resolvedClientId.isEmpty) {
          throw StateError(
            'Production cloud builds require explicit '
            'ICARUS_CONVEX_DEPLOYMENT_URL and ICARUS_CONVEX_CLIENT_ID values.',
          );
        }
        _requireHttpsUrl(resolvedDeploymentUrl);
        if (Uri.parse(resolvedDeploymentUrl).host == _developmentConvexHost ||
            resolvedClientId == developmentConvexClientId) {
          throw StateError(
            'Production cloud builds cannot use the Icarus development '
            'Convex deployment.',
          );
        }
        return CloudBuildConfig._(
          environment: resolvedEnvironment,
          deploymentUrl: resolvedDeploymentUrl,
          clientId: resolvedClientId,
        );
      default:
        throw StateError(
          "Unsupported ICARUS_CLOUD_ENVIRONMENT '$environment'. "
          "Use 'development' or 'production'.",
        );
    }
  }

  static void _requireHttpsUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw StateError('Convex deployment URL must be an absolute HTTPS URL.');
    }
  }
}

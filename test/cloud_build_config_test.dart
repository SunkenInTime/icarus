import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/config/cloud_build_config.dart';

void main() {
  group('CloudBuildConfig', () {
    test('debug builds default to the development environment', () {
      final config = CloudBuildConfig.forBuild(isReleaseMode: false);

      expect(config.environment, 'development');
      expect(config.deploymentUrl, developmentConvexDeploymentUrl);
    });

    test('release builds require an intentional environment', () {
      expect(
        () => CloudBuildConfig.forBuild(isReleaseMode: true),
        throwsStateError,
      );
    });

    test('release builds may intentionally select development', () {
      final config = CloudBuildConfig.forBuild(
        isReleaseMode: true,
        environment: 'development',
      );

      expect(config.environment, 'development');
      expect(config.deploymentUrl, developmentConvexDeploymentUrl);
    });

    test('development uses the named development deployment by default', () {
      final config = CloudBuildConfig.resolve(environment: 'development');

      expect(config.environment, 'development');
      expect(config.deploymentUrl, developmentConvexDeploymentUrl);
      expect(config.clientId, developmentConvexClientId);
    });

    test('development overrides must be supplied as a pair', () {
      expect(
        () => CloudBuildConfig.resolve(
          environment: 'development',
          deploymentUrl: 'https://custom-dev.convex.cloud',
        ),
        throwsStateError,
      );
    });

    test('production requires an explicit deployment URL and client ID', () {
      expect(
        () => CloudBuildConfig.resolve(environment: 'production'),
        throwsStateError,
      );
      expect(
        () => CloudBuildConfig.resolve(
          environment: 'production',
          deploymentUrl: 'https://production-example.convex.cloud',
        ),
        throwsStateError,
      );
    });

    test('production rejects the development deployment', () {
      expect(
        () => CloudBuildConfig.resolve(
          environment: 'production',
          deploymentUrl: '$developmentConvexDeploymentUrl/',
          clientId: 'icarus-production',
        ),
        throwsStateError,
      );
      expect(
        () => CloudBuildConfig.resolve(
          environment: 'production',
          deploymentUrl: 'https://production-example.convex.cloud',
          clientId: developmentConvexClientId,
        ),
        throwsStateError,
      );
    });

    test('production accepts a complete non-development configuration', () {
      final config = CloudBuildConfig.resolve(
        environment: 'production',
        deploymentUrl: 'https://production-example.convex.cloud',
        clientId: 'icarus-production',
      );

      expect(config.environment, 'production');
      expect(config.deploymentUrl, 'https://production-example.convex.cloud');
      expect(config.clientId, 'icarus-production');
    });

    test('unknown environments fail closed', () {
      expect(
        () => CloudBuildConfig.resolve(environment: 'staging'),
        throwsStateError,
      );
    });
  });
}

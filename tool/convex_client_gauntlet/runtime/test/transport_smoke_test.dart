import 'package:flutter_test/flutter_test.dart';
import 'package:icarus_convex_runtime_gauntlet/transport.dart';

const deploymentUrl = String.fromEnvironment('CONVEX_URL');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'both transports reach the same deployment',
    () async {
      final dartvex = DartvexTransport(deploymentUrl);
      final dartvexResult = await dartvex.query('users:me', const {});
      expect(dartvexResult, isNull);
      await dartvex.close();

      final convexFlutter = await ConvexFlutterTransport.create(deploymentUrl);
      final convexFlutterResult = await convexFlutter.query(
        'users:me',
        const {},
      );
      expect(convexFlutterResult, isNull);
      await convexFlutter.close();
    },
    skip: deploymentUrl.isEmpty ? 'Pass --dart-define=CONVEX_URL' : false,
  );
}

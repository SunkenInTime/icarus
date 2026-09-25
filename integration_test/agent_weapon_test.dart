import 'package:integration_test/integration_test.dart';

import '../test/agent_weapon_widgets_test.dart' as scenarios;

/// Runs the same interactions on the native desktop engine. The harness uses
/// in-memory providers and never opens the user's Hive library or other windows.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  scenarios.main();
}

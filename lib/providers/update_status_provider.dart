import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/update_checker.dart';
import 'package:icarus/providers/collab/client_upgrade_required_provider.dart';

final appUpdateStatusProvider = FutureProvider<UpdateCheckResult>((ref) async {
  // Checked again when the server refuses this build: the update it needs
  // may have shipped since the check at launch.
  ref.watch(clientUpgradeRequiredProvider);
  return UpdateChecker.checkForWindowsStoreUpdateSignal();
});

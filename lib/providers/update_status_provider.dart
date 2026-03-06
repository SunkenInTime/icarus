import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/update_checker.dart';

final appUpdateStatusProvider = FutureProvider<UpdateCheckResult>((ref) async {
  return UpdateChecker.checkForUpdateSignal();
});


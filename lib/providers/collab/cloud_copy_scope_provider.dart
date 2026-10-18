import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_library_copy.dart';
import 'package:icarus/providers/auth_provider.dart';

/// Whose cloud copy this computer reads and writes now: this build's
/// deployment and the signed-in account. Null while signed out.
final cloudCopyScopeProvider = Provider<CloudCopyScope?>((ref) {
  final accountId = ref.watch(authProvider.select((auth) => auth.user?.id));
  if (accountId == null) return null;
  return CloudCopyScope(
    deploymentUrl: ref.watch(cloudCopyDeploymentUrlProvider),
    accountId: accountId,
  );
});

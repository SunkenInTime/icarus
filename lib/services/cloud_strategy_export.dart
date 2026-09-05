import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/services/cloud_library_action.dart';
import 'package:icarus/strategy/strategy_import_export.dart';

Future<CloudLibraryActionResult> runCloudStrategyExport(
  WidgetRef ref,
  String strategyId,
) {
  const source = 'strategy:export';
  return ref.read(cloudLibraryActionReporterProvider).run(
        action: () => ref.read(cloudStrategyExporterProvider)(strategyId),
        source: source,
        failureMessage: "Couldn't export this cloud strategy. Try again.",
        showFailureMessage: true,
        reportAuthenticationFailure: (error, stackTrace) =>
            ref.read(authProvider.notifier).reportConvexUnauthenticated(
                  source: source,
                  error: error,
                  stackTrace: stackTrace,
                ),
      );
}

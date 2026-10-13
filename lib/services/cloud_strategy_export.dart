import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/services/cloud_library_action.dart';
import 'package:icarus/services/cloud_work_sent.dart';
import 'package:icarus/strategy/strategy_import_export.dart';

Future<CloudLibraryActionResult> runCloudStrategyExport(
  WidgetRef ref,
  String strategyId,
) {
  const source = 'strategy:export';
  final reporter = ref.read(cloudLibraryActionReporterProvider);
  return reporter.run(
    action: () async {
      try {
        return await ref.read(cloudStrategyExporterProvider)(strategyId);
      } on CloudWorkNotSent catch (error) {
        // Not a failure to retry at once: the file would leave out work.
        reporter.showMessage(
          cloudStrategyCopyRefusal(error, 'nothing was exported'),
        );
        return false;
      }
    },
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

import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/collab/convex_client.dart';
import 'package:icarus/collab/durable_cloud_media_outbox.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/config/cloud_build_config.dart';
import 'package:icarus/config/cloud_startup.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/services/local_image_file.dart' show deviceHasImageFiles;
import 'package:supabase_flutter/supabase_flutter.dart';

const cloudOutboxUnavailableReason =
    "Unsent cloud changes on this device couldn't be opened, so cloud sync "
    'is off for now. They are kept as they are. Your library on this device '
    'works as usual.';

const cloudClientsUnavailableReason =
    "Cloud sync couldn't start, so sign-in is unavailable. Your library on "
    'this device works as usual. Restart Icarus to try again.';

/// Brings up cloud sync: first the outboxes holding unsent cloud work, then
/// the Convex and Supabase clients. It never throws. The first step that
/// fails leaves the cloud unavailable for this run and the later steps unrun,
/// so a failure here can never keep anyone from the library on this device.
Future<CloudStartup> startCloud({
  required Future<void> Function() openOutboxes,
  required Future<void> Function() initializeClients,
}) async {
  try {
    await openOutboxes();
  } catch (error, stackTrace) {
    return _unavailable(cloudOutboxUnavailableReason, error, stackTrace);
  }
  try {
    await initializeClients();
  } catch (error, stackTrace) {
    return _unavailable(cloudClientsUnavailableReason, error, stackTrace);
  }
  return CloudStartup.ready;
}

CloudStartup _unavailable(String reason, Object error, StackTrace stackTrace) {
  AppErrorReporter.reportError(
    reason,
    error: error,
    stackTrace: stackTrace,
    source: 'startCloud',
    // Nothing is on screen yet; the app tells the user once it is.
    promptUser: false,
  );
  return CloudStartup.unavailable(reason);
}

/// Opens the boxes that hold unsent cloud work. Hive's crash recovery is off:
/// it truncates a box at its first unreadable frame, which would silently
/// delete every change saved after it. A box that will not open is left on
/// disk byte for byte, and the open fails.
Future<void> openCloudOutboxes() async {
  await Hive.openBox<dynamic>(
    HiveBoxNames.strategyOutboxBox,
    crashRecovery: false,
  );
  await prepareDurableStrategyOutbox();
  await Hive.openBox<dynamic>(
    HiveBoxNames.cloudMediaOutboxBox,
    crashRecovery: false,
  );
  await prepareDurableCloudMediaOutbox();
  if (!deviceHasImageFiles) {
    await Hive.openBox<dynamic>(
      HiveBoxNames.pendingMediaBytesBox,
      crashRecovery: false,
    );
  }
}

Future<void> initializeCloudClients(CloudBuildConfig config) async {
  await ConvexClient.initialize(
    ConvexConfig(
      deploymentUrl: config.deploymentUrl,
      clientId: config.clientId,
      operationTimeout: const Duration(seconds: 30),
      healthCheckQuery: defaultConvexHealthCheckQuery,
    ),
  );

  await Supabase.initialize(
    url: 'https://gjdirtrtgnawqoruavqn.supabase.co',
    anonKey: 'sb_publishable_6M0VCSZCvRFrcgNANWPVWw_U06T_rUo',
    authOptions: const FlutterAuthClientOptions(detectSessionInUri: false),
  );
}

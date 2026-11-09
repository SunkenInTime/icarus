// The app, as far as saving to the cloud goes, started the way main starts
// it: the cloud outboxes opened from a Hive directory on disk, the native
// Convex client, and the app's own providers (the op queue and its Hive
// outbox, the repository, the save state, the media queue and the sync
// chip's status). Two things stand in for the rest of the app:
//
// - Sign-in. The app gets its Convex token from Supabase; here the gauntlet
//   hands the native client minted tokens itself, and [GauntletAuth] reports
//   the account as signed in and ready, as AuthProvider does once it is.
// - The canvas. The gauntlet makes each edit as an op and queues it, as
//   live sync does from the canvas (see editor.dart).
//
// Faults go in below the repository (FaultyTransport) and below the native
// client (SocketProxy).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/collab/convex_client.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport_adapter.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_sync_status_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/startup/cloud_bootstrap.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

import 'faults.dart';

/// Signed in as [accountId] with the Convex user set up: what AuthProvider
/// reports once a Supabase session is in place. The gauntlet gives the
/// native client its tokens itself.
final class GauntletAuth extends AuthProvider {
  GauntletAuth(this.accountId);

  final String accountId;

  /// How many times the queue reported the server refusing its token.
  int unauthenticatedReports = 0;

  @override
  AppAuthState build() => AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: User(
          id: accountId,
          appMetadata: const <String, dynamic>{},
          userMetadata: const <String, dynamic>{},
          aud: 'authenticated',
          createdAt: '2026-01-01T00:00:00.000Z',
        ),
      );

  @override
  Future<void> reportConvexUnauthenticated({
    required String source,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    unauthenticatedReports += 1;
  }
}

final class GauntletApp {
  GauntletApp._({
    required this.container,
    required this.transport,
    required this.proxy,
    required this.auth,
  });

  final ProviderContainer container;
  final FaultyTransport transport;
  final SocketProxy proxy;
  final GauntletAuth auth;
  AuthHandleWrapper? _authHandle;
  String? _token;

  static bool _clientStarted = false;

  /// Starts the app on [hiveDirectory], connected to the deployment at
  /// [backendPort] through a proxy, signed in with [accessToken].
  static Future<GauntletApp> start({
    required String hiveDirectory,
    required int backendPort,
    required String accountId,
    required String accessToken,
  }) async {
    Hive.init(hiveDirectory);
    await openCloudOutboxes();

    final proxy = await SocketProxy.start(backendPort);
    if (_clientStarted) throw StateError('One app per process');
    _clientStarted = true;
    await ConvexClient.initialize(
      ConvexConfig(
        deploymentUrl: 'http://127.0.0.1:${proxy.port}',
        clientId: 'icarus-save-path-gauntlet',
        operationTimeout: const Duration(seconds: 30),
        healthCheckQuery: defaultConvexHealthCheckQuery,
      ),
    );
    final transport = FaultyTransport(
      PlatformConvexTransport(ConvexClient.instance),
    );
    final auth = GauntletAuth(accountId);
    final container = ProviderContainer(overrides: [
      authProvider.overrideWith(() => auth),
      convexStrategyRepositoryProvider.overrideWithValue(
        ConvexStrategyRepository(IcarusConvexApi(transport)),
      ),
    ]);
    appProviderContainer = container;
    final app = GauntletApp._(
      container: container,
      transport: transport,
      proxy: proxy,
      auth: auth,
    );
    await app.signIn(accessToken);
    await app.repository.ensureCurrentUser();
    // What the editor keeps alive while a cloud strategy is open.
    container.listen(cloudSyncStatusProvider, (prev, next) {
      final q = container.read(strategyOpQueueProvider);
      // ignore: avoid_print
      print('DBG ${DateTime.now().toIso8601String()} chip $prev -> $next '
          'lastError=${q.lastError} saveErr=${container.read(strategySaveStateProvider).cloudSyncError} '
          'queued=${q.queuedByEntityKey.length} inFlight=${q.inFlightByEntityKey.length} '
          'paused=${q.pausedByEntityKey.length} attn=${q.attentionByEntityKey.length}');
    });
    container.listen(strategyOpQueueProvider, (p, n) {
      if (p?.lastError != n.lastError) {
        // ignore: avoid_print
        print('DBG ${DateTime.now().toIso8601String()} queue lastError '
            '${n.lastError}');
      }
    });
    return app;
  }

  ConvexStrategyRepository get repository =>
      container.read(convexStrategyRepositoryProvider);

  StrategyOpQueueNotifier get queue =>
      container.read(strategyOpQueueProvider.notifier);

  StrategyOpQueueState get queueState =>
      container.read(strategyOpQueueProvider);

  /// What the sync chip shows.
  CloudSyncStatus get chip => container.read(cloudSyncStatusProvider);

  /// What the save state says: the save button and the leave guard read it.
  StrategySaveState get saveState => container.read(strategySaveStateProvider);

  /// Gives the native client [token], replacing the one it holds.
  Future<void> signIn(String token) async {
    // ignore: avoid_print
    print('DBG ${DateTime.now().toIso8601String()} signIn start');
    _authHandle?.dispose();
    _authHandle = null;
    await ConvexClient.instance.clearAuth();
    // The native handle clears auth when its cancellation wakes.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _token = token;
    _authHandle = await ConvexClient.instance.setAuthWithRefresh(
      fetchToken: () async {
        // ignore: avoid_print
        print('DBG ${DateTime.now().toIso8601String()} token fetched '
            '${_token.hashCode}');
        return _token;
      },
    );
    // ignore: avoid_print
    print('DBG ${DateTime.now().toIso8601String()} signIn done');
  }

  /// The token the client fetches the next time the server refuses the one
  /// it holds, as a session refresh would.
  void refreshTokenTo(String token) {
    // ignore: avoid_print
    print('DBG ${DateTime.now().toIso8601String()} token refreshed');
    _token = token;
  }

  /// Drops the native client's socket and waits for it to come back.
  Future<void> reconnect() async {
    final connected = await ConvexClient.instance
        .reconnect()
        .timeout(const Duration(seconds: 20));
    if (!connected) throw StateError('The native client did not reconnect');
  }

  /// Opens [strategyPublicId] in the editor: the strategy the queue works
  /// on, and the one the save state and chip describe.
  void open(String strategyPublicId) {
    container.read(strategyProvider.notifier).setFromState(StrategyState(
          strategyId: strategyPublicId,
          strategyName: strategyPublicId,
          source: StrategySource.cloud,
          storageDirectory: null,
          isOpen: true,
        ));
    queue.setActiveStrategy(strategyPublicId, accountId: auth.accountId);
  }

  /// The outbox records for the account as the Hive box holds them, read
  /// from the box rather than from the queue's own copy. (A box keeps what
  /// it wrote in memory too; the process restart reads the file itself.)
  List<DurableOutboxRecord> outboxOnDisk() {
    final box = Hive.box<dynamic>(HiveBoxNames.strategyOutboxBox);
    return [
      for (final key in box.keys)
        if (key != durableOutboxVersionKey)
          DurableOutboxRecord.fromJson(
            Map<String, dynamic>.from(box.get(key) as Map),
          ),
    ].where((record) => record.accountId == auth.accountId).toList();
  }

  Future<void> close() async {
    container.dispose();
    _authHandle?.dispose();
    await Hive.close();
    await proxy.close();
  }
}

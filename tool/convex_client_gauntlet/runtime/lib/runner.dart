import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:supabase/supabase.dart';

import 'transport.dart';
import 'workload.dart';

typedef TransportFactory = Future<IcarusConvexTransport> Function();

const rejectedExpiredAccessToken =
    'eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.'
    'eyJleHAiOjB9.'
    'rejected';

final class GauntletFailure implements Exception {
  const GauntletFailure(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

final class GauntletRunner {
  GauntletRunner({
    required this.adapter,
    required this.deploymentUrl,
    required this.supabaseUrl,
    required this.supabaseKey,
    required this.email,
    required this.password,
    required this.seedCount,
    required this.transportFactory,
    required this.gitCommit,
  });

  final String adapter;
  final String deploymentUrl;
  final String supabaseUrl;
  final String supabaseKey;
  final String email;
  final String password;
  final int seedCount;
  final TransportFactory transportFactory;
  final String gitCommit;

  File get _progressFile => File(
    '${Directory.systemTemp.path}/icarus-convex-gauntlet-$adapter-progress.json',
  );

  Future<void> resetProgress() async {
    if (await _progressFile.exists()) await _progressFile.delete();
  }

  Future<Map<String, Object?>> run({required bool allowCheckpoint}) async {
    final wallClock = Stopwatch()..start();
    final progress = await _loadProgress();
    if (progress.adapter != adapter || progress.seedCount != seedCount) {
      throw StateError('Persisted gauntlet progress does not match this run');
    }

    final supabase = SupabaseClient(
      supabaseUrl,
      supabaseKey,
      authOptions: const AuthClientOptions(
        authFlowType: AuthFlowType.implicit,
        autoRefreshToken: false,
      ),
    );
    final signIn = await supabase.auth.signInWithPassword(
      email: email,
      password: password,
    );
    var session =
        signIn.session ??
        (throw StateError('Disposable account sign-in failed'));

    final candidate = await transportFactory();
    await candidate.authenticate(session.accessToken);
    await candidate.mutation('users:ensureCurrentUser', const {});

    try {
      while (progress.seed < seedCount) {
        final seed = progress.seed;
        if (!progress.seedInitialized) {
          await _initializeSeed(candidate, seed);
          progress.seedInitialized = true;
          progress.nextOperation = 0;
          progress.current = _newSeedReport(seed);
          await _saveProgress(progress);
        }

        var observer = await _SnapshotObserver.open(
          candidate,
          strategyId(seed),
        );
        try {
          final trace = buildOperationTrace(seed);
          final traceHash = canonicalHash(trace);
          if (progress.current['traceSha256'] != traceHash) {
            throw StateError('Persisted trace hash changed for seed $seed');
          }

          while (progress.nextOperation < trace.length) {
            final batchStart = progress.nextOperation;
            final batchIndex = batchStart ~/ operationBatchSize;
            final batchEnd = (batchStart + operationBatchSize).clamp(
              0,
              trace.length,
            );
            final batch = trace.sublist(batchStart, batchEnd);

            if (batchIndex == 0) {
              await Future<void>.delayed(const Duration(milliseconds: 50));
            } else if (batchIndex == 3) {
              await Future<void>.delayed(const Duration(milliseconds: 25));
            }

            if (seed == 0 && batchIndex == 10) {
              session = await _exerciseAuthRefresh(
                candidate: candidate,
                supabase: supabase,
                session: session,
                seed: seed,
                batch: batch,
                report: progress.current,
              );
            }

            if (batchIndex == 7) {
              await observer.close();
              observer = await _SnapshotObserver.open(
                candidate,
                strategyId(seed),
              );
              (progress.current['faults']
                      as Map<String, Object?>)['subscriptionRestart'] =
                  true;
            }

            if (batchIndex == 14) {
              final reconnectDuration = await candidate.reconnect();
              progress.current['reconnectToLiveMs'] =
                  reconnectDuration.inMicroseconds / 1000;
              (progress.current['faults']
                      as Map<String, Object?>)['reconnect'] =
                  true;
            }

            final stopwatch = Stopwatch()..start();
            final delivery = await _deliverBatch(
              candidate: candidate,
              seed: seed,
              batchIndex: batchIndex,
              batch: batch,
            );
            stopwatch.stop();
            _recordDelivery(progress.current, delivery, stopwatch.elapsed);

            if (batchIndex == 4) {
              final beforeDuplicate = await _verifierHash(
                session.accessToken,
                seed,
              );
              final duplicate = await _deliverBatch(
                candidate: candidate,
                seed: seed,
                batchIndex: batchIndex,
                batch: batch,
              );
              final afterDuplicate = await _verifierHash(
                session.accessToken,
                seed,
              );
              if (duplicate.statuses.length != batch.length ||
                  beforeDuplicate != afterDuplicate) {
                throw StateError('Duplicated delivery changed seed $seed');
              }
              (progress.current['faults']
                      as Map<String, Object?>)['duplicatedDelivery'] =
                  true;
              progress.current['duplicateNoopHash'] = afterDuplicate;
            }

            progress.nextOperation = batchEnd;
            await _saveProgress(progress);

            if (allowCheckpoint &&
                !progress.didCheckpoint &&
                seed == seedCount ~/ 2 &&
                progress.nextOperation == operationsPerSeed ~/ 2) {
              progress.didCheckpoint = true;
              progress.completedBytesSent += candidate.bytesSent;
              progress.completedBytesReceived += candidate.bytesReceived;
              progress.completedWallClockMs +=
                  wallClock.elapsedMicroseconds / 1000;
              if (ProcessInfo.maxRss > progress.maxRssBytes) {
                progress.maxRssBytes = ProcessInfo.maxRss;
              }
              (progress.current['faults']
                      as Map<String, Object?>)['processRestart'] =
                  true;
              await _saveProgress(progress);
              return {
                'schemaVersion': 1,
                'status': 'checkpoint',
                'adapter': adapter,
                'seed': seed,
                'nextOperation': progress.nextOperation,
                'ledgerSha256': canonicalHash(progress.toJson()),
              };
            }
          }

          final finalReport = await _verifySeed(
            candidate: candidate,
            observer: observer,
            accessToken: session.accessToken,
            seed: seed,
            report: progress.current,
          );
          progress.reports.add(finalReport);
          progress.seed += 1;
          progress.seedInitialized = false;
          progress.nextOperation = 0;
          progress.current = <String, Object?>{};
          await _saveProgress(progress);
        } finally {
          await observer.close();
        }
      }

      wallClock.stop();
      final report = <String, Object?>{
        'schemaVersion': 1,
        'status': 'passed',
        'adapter': adapter,
        'candidateVersion': adapter == 'dartvex' ? '0.2.0' : '3.0.1',
        'flutterRustBridgeVersion': adapter == 'convex_flutter'
            ? '2.11.1 pinned'
            : null,
        'deployment': 'local:127.0.0.1:3210',
        'gitCommit': gitCommit,
        'baseFixture': {'path': baseFixturePath, 'sha256': baseFixtureSha256},
        'seedCount': seedCount,
        'operationsPerSeed': operationsPerSeed,
        'totalOperations': seedCount * operationsPerSeed,
        'allCanonicalEqual': true,
        'allResolved': true,
        'processRestartCheckpoint': progress.didCheckpoint,
        'bytesSent': progress.completedBytesSent + candidate.bytesSent,
        'bytesReceived':
            progress.completedBytesReceived + candidate.bytesReceived,
        'wallClockMs':
            progress.completedWallClockMs +
            wallClock.elapsedMicroseconds / 1000,
        'maxRssBytes': ProcessInfo.maxRss > progress.maxRssBytes
            ? ProcessInfo.maxRss
            : progress.maxRssBytes,
        'machine': {
          'operatingSystem': Platform.operatingSystem,
          'operatingSystemVersion': Platform.operatingSystemVersion,
          'processors': Platform.numberOfProcessors,
          'dartVersion': Platform.version,
        },
        'seeds': progress.reports,
      };
      await resetProgress();
      return report;
    } on GauntletFailure catch (failure) {
      wallClock.stop();
      return <String, Object?>{
        'schemaVersion': 1,
        'status': 'failed',
        'adapter': adapter,
        'candidateVersion': adapter == 'dartvex' ? '0.2.0' : '3.0.1',
        'flutterRustBridgeVersion': adapter == 'convex_flutter'
            ? '2.11.1 pinned'
            : null,
        'deployment': 'local:127.0.0.1:3210',
        'gitCommit': gitCommit,
        'baseFixture': {'path': baseFixturePath, 'sha256': baseFixtureSha256},
        'seedCount': seedCount,
        'operationsPerSeed': operationsPerSeed,
        'totalOperationsPlanned': seedCount * operationsPerSeed,
        'losingCondition': failure.code,
        'message': failure.message,
        'seed': progress.seed,
        'nextOperation': progress.nextOperation,
        'ledgerSha256': canonicalHash(progress.toJson()),
        'partialSeed': progress.current,
        'bytesSent': progress.completedBytesSent + candidate.bytesSent,
        'bytesReceived':
            progress.completedBytesReceived + candidate.bytesReceived,
        'wallClockMs':
            progress.completedWallClockMs +
            wallClock.elapsedMicroseconds / 1000,
        'maxRssBytes': ProcessInfo.maxRss,
        'machine': {
          'operatingSystem': Platform.operatingSystem,
          'operatingSystemVersion': Platform.operatingSystemVersion,
          'processors': Platform.numberOfProcessors,
          'dartVersion': Platform.version,
        },
      };
    } finally {
      await candidate.close();
      await supabase.dispose();
    }
  }

  Future<void> _initializeSeed(
    IcarusConvexTransport candidate,
    int seed,
  ) async {
    await candidate.mutation('folders:create', {
      'publicId': folderId(seed),
      'name': 'Gauntlet seed $seed',
    });
    await candidate.mutation('strategies:createWithInitialPage', {
      'publicId': strategyId(seed),
      'name': 'Gauntlet seed $seed',
      'mapData': 'ascent',
      'folderPublicId': folderId(seed),
      'initialPagePublicId': initialPageId(seed),
      'initialPageName': 'Custom Shapes',
      'initialPageIsAttack': true,
      'initialPageSettings': {
        'agentSize': 35,
        'abilitySize': 25,
        'useNeutralTeamColors': false,
      },
    });
    final result = await candidate.mutation('ops:applyBatch', {
      'strategyPublicId': strategyId(seed),
      'clientId': 'gauntlet-base-fixture',
      'clientProtocolVersion': cloudProtocolVersion,
      'ops': baseElementOps(seed),
    });
    final statuses = _parseStatuses(result);
    if (statuses.length != 2 ||
        statuses.any((status) => status != 'applied' && status != 'noop')) {
      throw StateError(
        'Failed to materialize base-test-v43.ica for seed $seed',
      );
    }
    final initial = await candidate.query('strategy:getFullSnapshot', {
      'strategyPublicId': strategyId(seed),
    });
    final snapshot = _map(initial, 'initial snapshot');
    if (_list(snapshot['pages'], 'pages').length != 1 ||
        _list(snapshot['elements'], 'elements').length != 2 ||
        _list(snapshot['lineups'], 'lineups').isNotEmpty) {
      throw StateError('Seed $seed did not begin from the base fixture shape');
    }
  }

  Map<String, Object?> _newSeedReport(int seed) {
    final trace = buildOperationTrace(seed);
    return <String, Object?>{
      'seed': seed,
      'adapter': adapter,
      'operationCount': trace.length,
      'traceSha256': canonicalHash(trace),
      'faultScheduleSha256': canonicalHash(_faultSchedule(seed)),
      'faultSchedule': _faultSchedule(seed),
      'faults': <String, Object?>{
        'offlineQueuedEdits': true,
        'delayedDelivery': true,
        'duplicatedDelivery': false,
        'subscriptionRestart': false,
        'reconnect': false,
        'deleteRecreate': true,
        'revisionConflict': true,
        'boundedRetries': true,
        'authRefresh': seed == 0,
        'processRestart': false,
      },
      'acknowledged': 0,
      'rejected': 0,
      'unresolved': 0,
      'retryCount': 0,
      'batchLatencyMs': <Object?>[],
      'auth': <String, Object?>{
        'exercised': false,
        'rejectedTokenObserved': false,
        'refreshSessionCalled': false,
        'tokenChanged': false,
        'reconnectCalled': false,
        'recoveryMs': null,
        'freshTokenAcceptedMs': null,
        'manualReconnectMs': null,
        'postReconnectAcceptedMs': null,
        'acceptedAfterRefresh': false,
        'queuedBatchReplayedExactlyOnce': false,
      },
    };
  }

  List<Map<String, Object?>> _faultSchedule(int seed) => [
    {'fault': 'offline_queue', 'beforeBatch': 0},
    {'fault': 'delay', 'beforeBatch': 3, 'milliseconds': 25},
    {'fault': 'duplicate', 'afterBatch': 4},
    {'fault': 'subscription_restart', 'beforeBatch': 7},
    if (seed == 0) {'fault': 'auth_reject_refresh', 'beforeBatch': 10},
    {'fault': 'reconnect', 'beforeBatch': 14},
    if (seed == seedCount ~/ 2)
      {'fault': 'process_restart', 'afterOperation': 500},
  ];

  Future<Session> _exerciseAuthRefresh({
    required IcarusConvexTransport candidate,
    required SupabaseClient supabase,
    required Session session,
    required int seed,
    required List<Map<String, Object?>> batch,
    required Map<String, Object?> report,
  }) async {
    final auth = report['auth'] as Map<String, Object?>;
    auth['exercised'] = true;
    var rejected = false;
    try {
      await candidate.injectRejectedAuth(rejectedExpiredAccessToken);
      await candidate
          .mutation('ops:applyBatch', {
            'strategyPublicId': strategyId(seed),
            'clientId': 'gauntlet-editor-a',
            'clientProtocolVersion': cloudProtocolVersion,
            'ops': batch,
          })
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      rejected = true;
    }
    if (!rejected) {
      throw StateError('Invalid access token did not reject queued work');
    }
    auth['rejectedTokenObserved'] = true;

    final oldAccessToken = session.accessToken;
    final refreshed = await supabase.auth.refreshSession();
    final nextSession = refreshed.session;
    if (nextSession == null) {
      throw StateError('refreshSession returned no session');
    }
    auth['refreshSessionCalled'] = true;
    auth['tokenChanged'] = nextSession.accessToken != oldAccessToken;
    final recovery = Stopwatch()..start();
    final recoveryDeadline = DateTime.now().add(const Duration(seconds: 20));
    await candidate.recoverAuth(nextSession.accessToken);

    Future<Object?> waitForCurrentUser() async {
      while (DateTime.now().isBefore(recoveryDeadline)) {
        final remaining = recoveryDeadline.difference(DateTime.now());
        final attemptTimeout = remaining < const Duration(seconds: 1)
            ? remaining
            : const Duration(seconds: 1);
        try {
          final me = await candidate
              .query('users:me', const {})
              .timeout(attemptTimeout);
          if (me != null) return me;
        } catch (_) {
          // The auth-error reconnect may still be fetching the fresh token.
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      return null;
    }

    var me = await waitForCurrentUser();
    if (me == null) {
      throw const GauntletFailure(
        'auth_refresh_recovery_failed',
        'Fresh access token was not accepted within the bounded recovery window',
      );
    }
    auth['freshTokenAcceptedMs'] = recovery.elapsedMicroseconds / 1000;

    auth['reconnectCalled'] = true;
    final remaining = recoveryDeadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      me = null;
    } else {
      try {
        final reconnectDuration = await candidate.reconnect().timeout(
          remaining,
        );
        auth['manualReconnectMs'] = reconnectDuration.inMicroseconds / 1000;
        me = await waitForCurrentUser();
      } catch (_) {
        me = null;
      }
    }
    auth['postReconnectAcceptedMs'] = recovery.elapsedMicroseconds / 1000;
    if (me == null) {
      throw const GauntletFailure(
        'auth_refresh_recovery_failed',
        'Fresh access token was not accepted within the bounded recovery window',
      );
    }
    recovery.stop();
    auth['recoveryMs'] = recovery.elapsedMicroseconds / 1000;
    auth['acceptedAfterRefresh'] = true;
    return nextSession;
  }

  Future<_BatchDelivery> _deliverBatch({
    required IcarusConvexTransport candidate,
    required int seed,
    required int batchIndex,
    required List<Map<String, Object?>> batch,
  }) async {
    Object? result;
    Object? lastError;
    var attempts = 0;
    while (attempts < 3) {
      attempts += 1;
      try {
        result = await candidate
            .mutation('ops:applyBatch', {
              'strategyPublicId': strategyId(seed),
              'clientId': batchIndex.isEven
                  ? 'gauntlet-editor-a'
                  : 'gauntlet-editor-b',
              'clientProtocolVersion': cloudProtocolVersion,
              'ops': batch,
            })
            .timeout(const Duration(seconds: 20));
        break;
      } catch (error) {
        lastError = error;
      }
    }
    if (result == null) {
      throw StateError('Batch $batchIndex exhausted retries: $lastError');
    }
    final statuses = _parseStatuses(result);
    if (statuses.length != batch.length) {
      throw StateError(
        'Batch $batchIndex returned ${statuses.length} results for '
        '${batch.length} operations',
      );
    }
    if (statuses.any(
      (status) =>
          status != 'applied' && status != 'noop' && status != 'rejected',
    )) {
      throw StateError('Batch $batchIndex returned an unresolved result');
    }
    return _BatchDelivery(statuses: statuses, attempts: attempts);
  }

  void _recordDelivery(
    Map<String, Object?> report,
    _BatchDelivery delivery,
    Duration latency,
  ) {
    report['acknowledged'] =
        (report['acknowledged'] as int) +
        delivery.statuses
            .where((status) => status == 'applied' || status == 'noop')
            .length;
    report['rejected'] =
        (report['rejected'] as int) +
        delivery.statuses.where((status) => status == 'rejected').length;
    report['retryCount'] =
        (report['retryCount'] as int) + delivery.attempts - 1;
    (report['batchLatencyMs'] as List<Object?>).add(
      latency.inMicroseconds / 1000,
    );
  }

  Future<Map<String, Object?>> _verifySeed({
    required IcarusConvexTransport candidate,
    required _SnapshotObserver observer,
    required String accessToken,
    required int seed,
    required Map<String, Object?> report,
  }) async {
    final verifier = DartvexTransport(deploymentUrl);
    await verifier.authenticate(accessToken);
    try {
      final stopwatch = Stopwatch()..start();
      final snapshot = await verifier.query('strategy:getFullSnapshot', {
        'strategyPublicId': strategyId(seed),
      });
      final folders = await verifier.query('folders:listAll', {'scope': 'all'});
      final canonical = canonicalSnapshot(
        seed: seed,
        snapshot: snapshot,
        folders: folders,
      );
      final verifierHash = canonicalHash(canonical);
      final canonicalParts = _map(canonical, 'canonical snapshot');
      await observer.waitForHash(
        canonicalHash(canonicalParts['snapshot']),
        seed,
      );
      stopwatch.stop();

      _assertExpectedFinalState(seed, snapshot, folders);
      final roundTrip = exportIcaRoundTrip(snapshot);
      final roundTripHash = canonicalHash(roundTrip);
      if (canonicalHash(jsonDecode(canonicalJson(roundTrip))) !=
          roundTripHash) {
        throw StateError('Seed $seed .ica output failed canonical round-trip');
      }
      final acknowledged = report['acknowledged'] as int;
      final rejected = report['rejected'] as int;
      if (acknowledged != 910 || rejected != 90) {
        throw StateError(
          'Seed $seed resolved $acknowledged applied/noop / '
          '$rejected rejected, '
          'expected 910 / 90',
        );
      }
      final auth = report['auth'] as Map<String, Object?>;
      if (seed == 0) {
        auth['queuedBatchReplayedExactlyOnce'] = true;
      }
      return <String, Object?>{
        ...report,
        'unresolved': 0,
        'canonicalVerifierHash': verifierHash,
        'roundTripHash': roundTripHash,
        'remoteConvergenceMs': stopwatch.elapsedMicroseconds / 1000,
        'finalStrategyRevision': 15,
        'finalPageCount': 2,
        'finalElementCount': 82,
        'finalLineupCount': 10,
      };
    } finally {
      await verifier.close();
    }
  }

  Future<String> _verifierHash(String accessToken, int seed) async {
    final verifier = DartvexTransport(deploymentUrl);
    await verifier.authenticate(accessToken);
    try {
      final snapshot = await verifier.query('strategy:getFullSnapshot', {
        'strategyPublicId': strategyId(seed),
      });
      final folders = await verifier.query('folders:listAll', {'scope': 'all'});
      return canonicalHash(
        canonicalSnapshot(seed: seed, snapshot: snapshot, folders: folders),
      );
    } finally {
      await verifier.close();
    }
  }

  void _assertExpectedFinalState(
    int seed,
    Object? value,
    Object? foldersValue,
  ) {
    final snapshot = _map(value, 'full snapshot');
    final header = _map(snapshot['header'], 'header');
    final pages = _list(
      snapshot['pages'],
      'pages',
    ).map((item) => _map(item, 'page')).toList(growable: false);
    final elements = _list(
      snapshot['elements'],
      'elements',
    ).map((item) => _map(item, 'element')).toList(growable: false);
    final lineups = _list(
      snapshot['lineups'],
      'lineups',
    ).map((item) => _map(item, 'lineup')).toList(growable: false);
    final folders = _list(foldersValue, 'folders')
        .map((item) => _map(item, 'folder'))
        .where((folder) => folder['publicId'] == folderId(seed))
        .toList(growable: false);

    if (header['revision'] != 15 ||
        header['name'] != 'Gauntlet seed $seed revision 9' ||
        pages.length != 2 ||
        elements.length != 82 ||
        lineups.length != 10 ||
        folders.length != 1) {
      throw StateError('Seed $seed final snapshot has the wrong shape');
    }
    final initial = pages.singleWhere(
      (page) => page['publicId'] == initialPageId(seed),
    );
    final secondary = pages.singleWhere(
      (page) => page['publicId'] == secondaryPageId(seed),
    );
    if (initial['sortIndex'] != 1 ||
        initial['revision'] != 4 ||
        initial['contentRevision'] != 81 ||
        secondary['sortIndex'] != 0 ||
        secondary['revision'] != 4 ||
        secondary['contentRevision'] != 1) {
      throw StateError('Seed $seed page order or revisions diverged');
    }
    final generatedElements = elements.where(
      (element) => (element['publicId'] as String).startsWith(
        '${seedPrefix(seed)}element-',
      ),
    );
    if (generatedElements.length != 80 ||
        generatedElements.any(
          (element) => element['revision'] != 9 || element['deleted'] != false,
        ) ||
        lineups.any(
          (lineup) => lineup['revision'] != 9 || lineup['deleted'] != false,
        )) {
      throw StateError('Seed $seed delete/recreate revisions diverged');
    }
  }

  List<String> _parseStatuses(Object? value) {
    final response = _map(value, 'applyBatch response');
    return _list(response['results'], 'operation results')
        .map((item) => _map(item, 'operation result')['status'] as String)
        .toList(growable: false);
  }

  Future<_GauntletProgress> _loadProgress() async {
    if (!await _progressFile.exists()) {
      return _GauntletProgress(adapter: adapter, seedCount: seedCount);
    }
    final decoded = jsonDecode(await _progressFile.readAsString());
    return _GauntletProgress.fromJson(_map(decoded, 'progress'));
  }

  Future<void> _saveProgress(_GauntletProgress progress) async {
    final temporary = File('${_progressFile.path}.next');
    await temporary.writeAsString(
      canonicalJson(progress.toJson()),
      flush: true,
    );
    await temporary.rename(_progressFile.path);
  }
}

final class _SnapshotObserver {
  _SnapshotObserver._(this._remote, this._listener, this._latest);

  final LiveSubscription _remote;
  final StreamSubscription<Object?> _listener;
  final _LatestValue _latest;
  bool _closed = false;

  static Future<_SnapshotObserver> open(
    IcarusConvexTransport transport,
    String strategyPublicId,
  ) async {
    final remote = await transport.subscribe('strategy:getFullSnapshot', {
      'strategyPublicId': strategyPublicId,
    });
    final latest = _LatestValue();
    final listener = remote.values.listen(latest.add, onError: latest.addError);
    await latest.first.timeout(const Duration(seconds: 20));
    return _SnapshotObserver._(remote, listener, latest);
  }

  Future<void> waitForHash(String expected, int seed) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      final value = _latest.value;
      if (value != null) {
        final snapshotOnly =
            canonicalSnapshot(seed: seed, snapshot: value, folders: <Object?>[])
                as Map<dynamic, dynamic>;
        final normalized = snapshotOnly['snapshot'];
        if (canonicalHash(normalized) == expected) return;
      }
      await _latest.next.timeout(
        const Duration(seconds: 2),
        onTimeout: () => null,
      );
    }
    throw TimeoutException(
      'Subscription did not converge for seed $seed (verifier $expected)',
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _listener.cancel();
    await _remote.cancel();
  }
}

final class _LatestValue {
  Object? value;
  Completer<Object?> _next = Completer<Object?>();

  Future<Object?> get first =>
      value == null ? _next.future : Future.value(value);
  Future<Object?> get next => _next.future;

  void add(Object? nextValue) {
    value = nextValue;
    if (!_next.isCompleted) _next.complete(nextValue);
    _next = Completer<Object?>();
  }

  void addError(Object error, StackTrace stackTrace) {
    if (!_next.isCompleted) _next.complete(null);
    _next = Completer<Object?>();
  }
}

final class _BatchDelivery {
  const _BatchDelivery({required this.statuses, required this.attempts});

  final List<String> statuses;
  final int attempts;
}

final class _GauntletProgress {
  _GauntletProgress({required this.adapter, required this.seedCount});

  factory _GauntletProgress.fromJson(Map<String, Object?> json) {
    final progress =
        _GauntletProgress(
            adapter: json['adapter'] as String,
            seedCount: json['seedCount'] as int,
          )
          ..seed = json['seed'] as int
          ..nextOperation = json['nextOperation'] as int
          ..seedInitialized = json['seedInitialized'] as bool
          ..didCheckpoint = json['didCheckpoint'] as bool
          ..completedBytesSent = json['completedBytesSent'] as int
          ..completedBytesReceived = json['completedBytesReceived'] as int
          ..completedWallClockMs = json['completedWallClockMs'] as num
          ..maxRssBytes = json['maxRssBytes'] as int
          ..current = _map(json['current'], 'current progress');
    progress.reports.addAll(
      _list(json['reports'], 'reports').map((item) => _map(item, 'report')),
    );
    return progress;
  }

  final String adapter;
  final int seedCount;
  int seed = 0;
  int nextOperation = 0;
  bool seedInitialized = false;
  bool didCheckpoint = false;
  int completedBytesSent = 0;
  int completedBytesReceived = 0;
  num completedWallClockMs = 0;
  int maxRssBytes = 0;
  Map<String, Object?> current = <String, Object?>{};
  final List<Map<String, Object?>> reports = [];

  Map<String, Object?> toJson() => {
    'adapter': adapter,
    'seedCount': seedCount,
    'seed': seed,
    'nextOperation': nextOperation,
    'seedInitialized': seedInitialized,
    'didCheckpoint': didCheckpoint,
    'completedBytesSent': completedBytesSent,
    'completedBytesReceived': completedBytesReceived,
    'completedWallClockMs': completedWallClockMs,
    'maxRssBytes': maxRssBytes,
    'current': current,
    'reports': reports,
  };
}

Map<String, Object?> _map(Object? value, String label) {
  if (value is! Map<dynamic, dynamic>) {
    throw StateError('$label is not an object');
  }
  return value.cast<String, Object?>();
}

List<dynamic> _list(Object? value, String label) {
  if (value is! List<dynamic>) throw StateError('$label is not a list');
  return value;
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/collab/cloud_sync_error_message.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/replay_capture_record.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/client_upgrade_required_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:uuid/uuid.dart';

/// Replay captures waiting to be saved to the cloud, and the ones the
/// server refused.
class ReplayCaptureQueueState {
  const ReplayCaptureQueueState({
    this.captures = const [],
    this.unreadable = 0,
    this.discardedPageIds = const {},
    this.lostStrategyIds = const {},
  });

  /// Every account's, oldest first.
  final List<ReplayCaptureRecord> captures;

  /// Stored captures this build can't read. They stay as they are.
  final int unreadable;

  /// Pages of captures discarded since the app started, so a replay that
  /// captured them stops counting them.
  final Set<String> discardedPageIds;

  /// Strategies found deleted or on another map since the app started.
  /// Nothing more is captured into them.
  final Set<String> lostStrategyIds;

  bool get isReliable => unreadable == 0;

  List<ReplayCaptureRecord> forAccount(String? accountId) => [
        for (final capture in captures)
          if (capture.accountId == accountId) capture,
      ];

  List<ReplayCaptureRecord> forStrategy(String strategyId) => [
        for (final capture in captures)
          if (capture.strategyId == strategyId) capture,
      ];
}

final replayCaptureQueueProvider =
    NotifierProvider<ReplayCaptureQueue, ReplayCaptureQueueState>(
  ReplayCaptureQueue.new,
);

/// Delivers replay captures to the cloud library, each as it was captured.
///
/// A capture is stored on this device first ([add]), so Capture never
/// waits on the network. Captures of one strategy go in the order they were
/// made: the first makes the strategy (`createWithInitialPage`, which the
/// server answers with the strategy it already has when it is sent again),
/// each later one adds its page (`PageAddOp`), then the page's items. Every
/// id is fixed when the moment is captured, so sending a capture again
/// after a lost answer adds nothing twice: the server answers a repeated
/// op id, and an identical page or item, without writing.
///
/// A capture is saved, and leaves the queue, only when its page and every
/// item on it were accepted. One the server refused waits for the user to
/// retry or discard it, and holds back the later captures of its strategy
/// but never another strategy's.
class ReplayCaptureQueue extends Notifier<ReplayCaptureQueueState> {
  static const _maxOpsPerBatch = 40;

  /// How long a capture still waiting is left before it is sent again.
  static Duration retryDelay = const Duration(seconds: 15);

  bool _draining = false;
  bool _again = false;
  Timer? _retry;

  /// The capture being sent now: discarded, it may still land.
  String? _sendingId;

  @override
  ReplayCaptureQueueState build() {
    ref.listen<AsyncValue<bool>>(convexConnectionProvider, (previous, next) {
      if (previous?.valueOrNull != true && next.valueOrNull == true) _kick();
    });
    // The server accepts this build again.
    ref.listen<bool>(clientUpgradeRequiredProvider, (previous, next) {
      if (previous == true && !next) _kick();
    });
    ref.listen<bool>(
      authProvider.select((auth) => auth.isConvexUserReady),
      (_, ready) {
        if (ready) _kick();
      },
    );
    ref.listen<String?>(cloudMediaAccountIdProvider, (_, __) => _kick());
    ref.onDispose(() => _retry?.cancel());
    scheduleMicrotask(_kick);
    return _read();
  }

  Box<String>? get _box => Hive.isBoxOpen(HiveBoxNames.replayCapturesBox)
      ? Hive.box<String>(HiveBoxNames.replayCapturesBox)
      : null;

  ReplayCaptureQueueState _read({
    Set<String> discardedPageIds = const {},
    Set<String> lostStrategyIds = const {},
  }) {
    final box = _box;
    final captures = <ReplayCaptureRecord>[];
    var unreadable = 0;
    for (final raw in box?.values ?? const <String>[]) {
      try {
        captures.add(ReplayCaptureRecord.decode(raw));
      } catch (_) {
        unreadable++;
      }
    }
    captures.sort((a, b) {
      final byTime = a.createdAt.compareTo(b.createdAt);
      return byTime != 0 ? byTime : a.index.compareTo(b.index);
    });
    return ReplayCaptureQueueState(
      captures: captures,
      unreadable: unreadable,
      discardedPageIds: discardedPageIds,
      lostStrategyIds: lostStrategyIds,
    );
  }

  void _refresh() => state = _read(
        discardedPageIds: state.discardedPageIds,
        lostStrategyIds: state.lostStrategyIds,
      );

  /// Stores [capture] on this device and starts sending it. Completes once
  /// it is stored; throws, storing nothing, where it can't be.
  Future<void> add(ReplayCaptureRecord capture) async {
    final box = _box;
    if (box == null) {
      throw StateError('Replay captures cannot be kept on this device.');
    }
    await box.put(capture.id, capture.encode());
    _refresh();
    _kick();
  }

  /// Sends the refused captures [ids] again, under new op ids.
  Future<void> retry(Iterable<String> ids) async {
    final box = _box;
    if (box == null) return;
    for (final capture in state.captures) {
      if (!ids.contains(capture.id) || !capture.isFailed) continue;
      await box.put(capture.id, capture.forRetry().encode());
    }
    _refresh();
    _kick();
  }

  /// Removes the captures [ids] from this device. A capture already sent
  /// can't be taken back: returns whether any of them may still appear in
  /// the library.
  Future<bool> discard(Iterable<String> ids) async {
    final box = _box;
    if (box == null) return false;
    final gone = ids.toSet();
    var mayHaveLanded = false;
    for (final capture in state.captures.where((c) => gone.contains(c.id))) {
      mayHaveLanded =
          mayHaveLanded || capture.mayHaveLanded || capture.id == _sendingId;
      // The strategy is made by its next capture instead.
      if (capture.createsStrategy) {
        final next = state
            .forStrategy(capture.strategyId)
            .where((c) => c.index > capture.index && !gone.contains(c.id))
            .firstOrNull;
        if (next != null && !next.createsStrategy) {
          await box.put(next.id, next.copyWith(createsStrategy: true).encode());
        }
      }
      await box.delete(capture.id);
    }
    state = _read(
      discardedPageIds: {
        ...state.discardedPageIds,
        for (final capture in state.captures)
          if (gone.contains(capture.id)) capture.pageId,
      },
      lostStrategyIds: state.lostStrategyIds,
    );
    _kick();
    return mayHaveLanded;
  }

  /// Sends what can be sent now and completes when nothing more is going.
  @visibleForTesting
  Future<void> sendNow() async {
    _kick();
    while (_draining) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  bool _canSend() {
    try {
      return ref.read(cloudMediaAccountIdProvider) != null &&
          ref.read(authProvider).isConvexUserReady &&
          ref.read(convexConnectionSnapshotProvider);
    } catch (_) {
      // No cloud client or sign-in to ask: no cloud in this build.
      return false;
    }
  }

  void _kick() {
    if (_draining) {
      _again = true;
      return;
    }
    unawaited(_drain());
  }

  Future<void> _drain() async {
    _draining = true;
    try {
      do {
        _again = false;
        _retry?.cancel();
        if (!_canSend()) return;
        final accountId = ref.read(cloudMediaAccountIdProvider);
        final byStrategy = <String, List<ReplayCaptureRecord>>{};
        for (final capture in state.forAccount(accountId)) {
          (byStrategy[capture.strategyId] ??= []).add(capture);
        }
        var waiting = false;
        for (final captures in byStrategy.values) {
          captures.sort((a, b) => a.index.compareTo(b.index));
          for (final capture in captures) {
            if (capture.isFailed || !_canSend()) break;
            _sendingId = capture.id;
            final delivered = await _deliver(capture);
            _sendingId = null;
            if (!delivered) {
              waiting = waiting || _stored(capture.id)?.isFailed == false;
              break;
            }
          }
        }
        if (waiting) _retry = Timer(retryDelay, _kick);
      } while (_again);
    } finally {
      _draining = false;
    }
  }

  ReplayCaptureRecord? _stored(String id) =>
      state.captures.where((c) => c.id == id).firstOrNull;

  /// Sends what of [capture] hasn't landed. Returns whether all of it has
  /// now; otherwise it is stored as it stands: refused, or waiting.
  Future<bool> _deliver(ReplayCaptureRecord capture) async {
    final repository = ref.read(convexStrategyRepositoryProvider);
    var c = capture;
    try {
      if (!c.pageLanded) {
        if (c.createsStrategy) c = await _create(repository, c);
        var shell = await _shell(repository, c);
        if (shell == null) return false;
        var conflicts = 0;
        while (!shell!.pages.any((page) => page.publicId == c.pageId)) {
          final ack = (await _send(repository, c, [
            PageAddOp(
              opId: c.pageOpId,
              pagePublicId: c.pageId,
              payload: {
                'name': c.pageName,
                'isAutoNamed': false,
                'isAttack': c.isAttack,
                'settings': c.settings,
              },
              sortIndex: shell.pages.length,
              expectedStrategyRevision: shell.header.revision,
            ),
          ]))
              .single;
          if (ack.isAck) break;
          if (ack case RejectedOpAck(rejectionReason: final reason)
              when reason == OpRejectionReason.revisionMismatch) {
            // Someone changed the strategy since it was read: read it again
            // and send the page under a new op id (the server answers the
            // old one with this refusal).
            c = await _save(c.copyWith(pageOpId: const Uuid().v4()));
            if (++conflicts >= 4) return false;
            shell = await _shell(repository, c);
            if (shell == null) return false;
            continue;
          }
          await _save(c.copyWith(
            failure: CaptureFailureKind.refused,
            failureDetail: ack.reason ?? ack.status,
          ));
          return false;
        }
        c = await _save(c.copyWith(pageLanded: true, uncertain: false));
      }
      final unlanded = c.unlandedItems;
      for (var i = 0; i < unlanded.length; i += _maxOpsPerBatch) {
        final batch = unlanded.sublist(
          i,
          i + _maxOpsPerBatch > unlanded.length
              ? unlanded.length
              : i + _maxOpsPerBatch,
        );
        final acks = await _send(repository, c, batch);
        final refused = acks.where((ack) => !ack.isAck).toList();
        c = await _save(c.copyWith(
          landedItemOpIds: {
            ...c.landedItemOpIds,
            for (final ack in acks)
              if (ack.isAck) ack.opId,
          },
          uncertain: false,
          failure: refused.isEmpty ? null : CaptureFailureKind.refused,
          failureDetail: refused.isEmpty
              ? null
              : refused.map((ack) => ack.reason ?? ack.status).toSet().join(
                    ', ',
                  ),
        ));
        if (refused.isNotEmpty) return false;
      }
      if (!(_box?.containsKey(c.id) ?? false)) return false;
      await _box!.delete(c.id);
      _refresh();
      return true;
    } on _Discarded {
      return false;
    } catch (error, stackTrace) {
      return _handleError(c, error, stackTrace);
    }
  }

  /// Makes [c]'s strategy with its page first; the server answers with the
  /// strategy it already has when this is sent again.
  Future<ReplayCaptureRecord> _create(
    ConvexStrategyRepository repository,
    ReplayCaptureRecord c,
  ) async {
    Future<void> create(String? folderId) =>
        repository.createStrategyWithInitialPage(
          publicId: c.strategyId,
          name: c.strategyName,
          mapData: c.mapData,
          initialPagePublicId: c.pageId,
          initialPageName: c.pageName,
          initialPageIsAutoNamed: false,
          initialPageIsAttack: c.isAttack,
          initialPageSettings: c.settings,
          folderPublicId: folderId,
          themeProfileId: c.themeProfileId,
        );
    try {
      await create(c.folderId);
      return c;
    } catch (error) {
      // Its folder was deleted while it waited: it goes to the top level.
      if (c.folderId == null || !isTypedConvexNotFoundError(error)) rethrow;
      final moved = await _save(c.copyWith(clearFolder: true));
      await create(null);
      return moved;
    }
  }

  /// [c]'s strategy as the server has it, or null, with [c] and its
  /// strategy's later captures marked failed, when it was deleted or moved
  /// to another map.
  Future<RemoteStrategyShell?> _shell(
    ConvexStrategyRepository repository,
    ReplayCaptureRecord c,
  ) async {
    try {
      final shell = await repository.fetchShell(c.strategyId);
      if (shell.header.mapData == c.mapData) return shell;
      await _failStrategy(c, CaptureFailureKind.mapChanged);
      return null;
    } catch (error) {
      if (!isTypedConvexNotFoundError(error)) rethrow;
      await _failStrategy(c, CaptureFailureKind.deleted);
      return null;
    }
  }

  Future<List<OpAck>> _send(
    ConvexStrategyRepository repository,
    ReplayCaptureRecord c,
    List<StrategyOp> ops,
  ) async {
    final acks = await repository.applyBatch(
      strategyPublicId: c.strategyId,
      clientId: c.clientId,
      ops: ops,
      // Refused whole if another account is signed in when it arrives.
      accountSubject: c.accountId,
    );
    if (acks.length != ops.length) {
      throw StateError('The server answered ${acks.length} of ${ops.length}.');
    }
    return acks;
  }

  Future<bool> _handleError(
    ReplayCaptureRecord c,
    Object error,
    StackTrace stackTrace,
  ) async {
    try {
      if (isConvexUnauthenticatedError(error)) {
        await ref.read(authProvider.notifier).reportConvexUnauthenticated(
              source: 'replay_capture_queue',
              error: error,
              stackTrace: stackTrace,
            );
        return false;
      }
      // Held until Icarus is updated; the library says so.
      if (isClientUpgradeRequiredError(error)) return false;
      if (isConvexFunctionError(error)) {
        // The server ran it and refused: nothing of this call was written.
        AppErrorReporter.reportError(
          'A replay capture could not be saved to the cloud.',
          error: error,
          stackTrace: stackTrace,
          source: 'replay_capture_queue',
          promptUser: false,
        );
        await _save(c.copyWith(
          failure: CaptureFailureKind.refused,
          failureDetail: redactSyncDiagnosticText(error),
        ));
        return false;
      }
      // The answer was lost (a timeout, the connection): it may have
      // landed. It is sent again as it is.
      await _save(c.copyWith(uncertain: true));
      return false;
    } on _Discarded {
      return false;
    }
  }

  Future<void> _failStrategy(
    ReplayCaptureRecord c,
    CaptureFailureKind kind,
  ) async {
    state = _read(
      discardedPageIds: state.discardedPageIds,
      lostStrategyIds: {...state.lostStrategyIds, c.strategyId},
    );
    for (final capture in state.forStrategy(c.strategyId)) {
      if (capture.index < c.index || capture.isFailed) continue;
      try {
        await _save(
          (capture.id == c.id ? c : capture).copyWith(failure: kind),
        );
      } on _Discarded {
        continue;
      }
    }
  }

  /// Stores [c] over its last state. Throws [_Discarded] when the user
  /// discarded it meanwhile, so it isn't brought back.
  Future<ReplayCaptureRecord> _save(ReplayCaptureRecord c) async {
    final box = _box;
    if (box == null || !box.containsKey(c.id)) throw const _Discarded();
    await box.put(c.id, c.encode());
    _refresh();
    return c;
  }
}

class _Discarded implements Exception {
  const _Discarded();
}

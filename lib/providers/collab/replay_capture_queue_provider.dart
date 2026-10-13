import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/collab/cloud_sync_error_message.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/replay_capture_record.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
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
    this.stuck = const {},
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

  /// Captures an error on this device stopped (their progress couldn't be
  /// stored), by id, with what to tell the user. They wait for Retry.
  final Map<String, String> stuck;

  /// Whether every capture is readable and its progress stored.
  bool get isReliable => unreadable == 0 && stuck.isEmpty;

  /// Whether [capture] waits for the user: refused, or stopped here.
  bool needsUser(ReplayCaptureRecord capture) =>
      capture.isFailed || stuck.containsKey(capture.id);

  List<ReplayCaptureRecord> forAccount(String? accountId) => [
        for (final capture in captures)
          if (capture.accountId == accountId) capture,
      ];

  List<ReplayCaptureRecord> forStrategy(String strategyId) => [
        for (final capture in captures)
          if (capture.strategyId == strategyId) capture,
      ];
}

/// The box replay captures are kept in; null where it isn't open (no cloud
/// in this build).
final replayCapturesBoxProvider = Provider<Box<String>?>(
  (ref) => Hive.isBoxOpen(HiveBoxNames.replayCapturesBox)
      ? Hive.box<String>(HiveBoxNames.replayCapturesBox)
      : null,
);

/// Tells the user something about their captures that happened away from
/// the replay.
final replayCaptureMessageProvider = Provider<void Function(String message)>(
  (ref) => (message) => Settings.showToast(
        message: message,
        backgroundColor: Settings.tacticalVioletTheme.primary,
        autoCloseDuration: const Duration(seconds: 6),
      ),
);

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

  final Set<String> _discardedPageIds = {};
  final Set<String> _lostStrategyIds = {};
  final Map<String, String> _stuck = {};

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

  Box<String>? get _box => ref.read(replayCapturesBoxProvider);

  ReplayCaptureQueueState _read() {
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
      discardedPageIds: {..._discardedPageIds},
      lostStrategyIds: {..._lostStrategyIds},
      stuck: {..._stuck},
    );
  }

  void _refresh() => state = _read();

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

  /// Sends the captures [ids] again: refused ones under new op ids, ones
  /// stopped here as they stand.
  Future<void> retry(Iterable<String> ids) async {
    final box = _box;
    if (box == null) return;
    _stuck.removeWhere((id, _) => ids.contains(id));
    try {
      for (final capture in state.captures) {
        if (!ids.contains(capture.id) || !capture.isFailed) continue;
        await box.put(capture.id, capture.forRetry().encode());
      }
    } finally {
      _refresh();
      _kick();
    }
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
      _stuck.remove(capture.id);
      _discardedPageIds.add(capture.pageId);
    }
    _refresh();
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
    // The server refuses this build: nothing goes until that clears.
    if (ref.read(clientUpgradeRequiredProvider)) return false;
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
            if (state.needsUser(capture) || !_canSend()) break;
            _sendingId = capture.id;
            bool delivered;
            try {
              delivered = await _deliver(capture);
            } catch (error, stackTrace) {
              // Stops this strategy's captures, never the others'.
              _stick(capture, error, stackTrace);
              delivered = false;
            } finally {
              _sendingId = null;
            }
            if (!delivered) {
              final stored = _stored(capture.id);
              waiting = waiting || (stored != null && !state.needsUser(stored));
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
      if (c.createsStrategy && !c.pageLanded) c = await _create(repository, c);
      // Read before anything more is sent, every time: the strategy may
      // have been deleted or moved to another map since the last send.
      var shell = await _shell(repository, c);
      if (shell == null) return false;
      if (c.pageLanded &&
          !shell.pages.any((page) => page.publicId == c.pageId)) {
        await _save(c.copyWith(failure: CaptureFailureKind.pageDeleted));
        return false;
      }
      if (!c.pageLanded) {
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
        // Item adds aren't checked against the strategy's map or revision:
        // read it again before each batch, so items never land on a
        // strategy that moved to another map, or a page deleted, meanwhile.
        final current = await _shell(repository, c);
        if (current == null) return false;
        if (!current.pages.any((page) => page.publicId == c.pageId)) {
          await _save(c.copyWith(failure: CaptureFailureKind.pageDeleted));
          return false;
        }
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
      final box = _box;
      if (box == null || !box.containsKey(c.id)) return false;
      try {
        await box.delete(c.id);
      } catch (error, stackTrace) {
        throw _StorageFailed(error, stackTrace);
      }
      _refresh();
      return true;
    } on _Discarded {
      return false;
    } on _StorageFailed {
      rethrow;
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
      // Its folder was deleted while it waited, or isn't this account's:
      // it goes to the top level.
      if (c.folderId == null ||
          !(isTypedConvexNotFoundError(error) ||
              isTypedConvexForbiddenError(error))) {
        rethrow;
      }
      final moved = await _save(c.copyWith(clearFolder: true));
      await create(null);
      ref.read(replayCaptureMessageProvider)(
        '"${c.strategyName}" is at the top level of My Library: the folder '
        'it was captured into is gone or not yours.',
      );
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
      // Held until Icarus is updated; noted, so the app and the replay say
      // so.
      if (ref.read(clientUpgradeRequiredProvider.notifier).noteError(error)) {
        return false;
      }
      // The strategy is gone (a whole batch refused as not found).
      if (isTypedConvexNotFoundError(error)) {
        await _failStrategy(c, CaptureFailureKind.deleted);
        return false;
      }
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
    _lostStrategyIds.add(c.strategyId);
    _refresh();
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
    try {
      await box.put(c.id, c.encode());
    } catch (error, stackTrace) {
      throw _StorageFailed(error, stackTrace);
    }
    _refresh();
    return c;
  }

  /// Keeps [capture] here, unsent, until the user retries: something on
  /// this device (its storage, most likely) stopped it.
  void _stick(
    ReplayCaptureRecord capture,
    Object error,
    StackTrace stackTrace,
  ) {
    final cause = error is _StorageFailed ? error.error : error;
    AppErrorReporter.reportError(
      'A replay capture could not be kept up to date on this device.',
      error: cause,
      stackTrace: error is _StorageFailed ? error.stackTrace : stackTrace,
      source: 'replay_capture_queue',
      promptUser: false,
    );
    _stuck[capture.id] = error is _StorageFailed
        ? "Icarus couldn't store its progress on this device."
        : 'Something on this device stopped it.';
    try {
      _refresh();
    } catch (_) {
      // The box can't be read either: show what is known.
      state = ReplayCaptureQueueState(
        captures: state.captures,
        unreadable: state.unreadable,
        discardedPageIds: {..._discardedPageIds},
        lostStrategyIds: {..._lostStrategyIds},
        stuck: {..._stuck},
      );
    }
  }
}

class _Discarded implements Exception {
  const _Discarded();
}

/// Writing a capture's progress to its box failed.
class _StorageFailed implements Exception {
  const _StorageFailed(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}

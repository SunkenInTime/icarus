import 'dart:async';
import 'dart:collection';
import 'dart:developer';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_library_copy.dart';
import 'package:icarus/collab/cloud_strategy_copy_box.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_copy_scope_provider.dart';
import 'package:icarus/providers/collab/cloud_media_cache_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';

/// Whether [strategyId] can be opened from the copy on this computer. Read
/// while offline, so the library can mark the strategies that need a
/// connection the first time.
final strategyKeptOfflineProvider =
    Provider.autoDispose.family<bool, String>((ref, strategyId) {
  ref.watch(cloudOfflineProvider);
  final scope = ref.watch(cloudCopyScopeProvider);
  if (scope == null) return false;
  return ref.watch(cloudStrategyCopyStoreProvider).keepsStrategy(
        scope,
        strategyId,
      );
});

/// How old a strategy's copy may get before the background refresh reads it
/// again.
const strategyCopyMaxAge = Duration(hours: 24);

/// The pause between two background reads, so they stay out of the way of
/// the editor's own.
const _backgroundPause = Duration(milliseconds: 500);

final strategyCopyRefresherProvider =
    NotifierProvider<StrategyCopyRefresher, void>(StrategyCopyRefresher.new);

/// Fills the copy of cloud strategies kept on this computer, one strategy at
/// a time: the whole of a strategy opened online, and, once the cloud
/// connects, every strategy in My Library and Shared whose copy is missing
/// or older than [strategyCopyMaxAge]. Each one brings its placed and
/// lineup images onto disk too.
class StrategyCopyRefresher extends Notifier<void> {
  final _queue = Queue<String>();
  final _queued = <String>{};
  bool _running = false;
  bool _walking = false;
  int _generation = 0;

  @override
  void build() {
    ref.listen<bool>(_cloudReadyProvider, (previous, next) {
      if (next && previous != true) unawaited(refreshLibrary());
    }, fireImmediately: true);
    ref.listen<CloudCopyScope?>(cloudCopyScopeProvider, (previous, next) {
      if (previous != next) _reset();
    });
    ref.onDispose(_reset);
  }

  /// Reads all of [strategyId], just opened online, into the copy ahead of
  /// anything else waiting.
  void keepOpenedStrategy(String strategyId) {
    if (!_keepsCopies) return;
    _queue.remove(strategyId);
    _queue.addFirst(strategyId);
    _queued.add(strategyId);
    unawaited(_drain());
  }

  /// Walks My Library and Shared and queues every strategy whose copy is
  /// missing or old. A strategy the walk no longer finds is dropped from the
  /// copy, but only after every list was read.
  Future<void> refreshLibrary() async {
    if (_walking) return;
    final scope = ref.read(cloudCopyScopeProvider);
    final store = ref.read(cloudStrategyCopyStoreProvider);
    if (scope == null || !_keepsCopies) return;
    _walking = true;
    final generation = _generation;
    try {
      final strategyIds = await _listStrategies();
      if (generation != _generation) return;
      final now = DateTime.now();
      for (final id in strategyIds) {
        final refreshed = store.lastFullRefresh(scope, id);
        final stale = refreshed == null ||
            now.difference(refreshed) > strategyCopyMaxAge ||
            !store.keepsStrategy(scope, id);
        if (stale && _queued.add(id)) _queue.addLast(id);
      }
      for (final id in store.keptStrategyIds(scope)) {
        if (!strategyIds.contains(id)) {
          await store.deleteStrategy(scope, id);
        }
      }
      unawaited(_drain());
    } catch (error, stackTrace) {
      log('Listing strategies to keep offline failed: $error',
          name: 'strategy_copy', error: error, stackTrace: stackTrace);
    } finally {
      _walking = false;
    }
  }

  /// Every strategy the signed-in account can open from its library: its
  /// own, those shared with it, and those inside folders shared with it.
  Future<Set<String>> _listStrategies() async {
    final repository = ref.read(convexStrategyRepositoryProvider);
    final inventory = await repository.fetchInventory();
    final shared = await repository.fetchSharedStrategies();
    final sharedFolders = await repository.fetchFolders(scope: 'shared');
    final ids = <String>{
      ...inventory.strategies.keys,
      for (final entry in shared) entry.strategy.id,
    };
    for (final folder in sharedFolders) {
      final strategies = await repository.fetchStrategiesForFolder(
        folder.folder.id,
        scope: 'shared',
      );
      ids.addAll(strategies.map((entry) => entry.strategy.id));
    }
    return ids;
  }

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    final generation = _generation;
    try {
      while (_queue.isNotEmpty && generation == _generation) {
        final strategyId = _queue.removeFirst();
        _queued.remove(strategyId);
        final answered = await _keepStrategy(strategyId);
        if (!answered) {
          // Offline: the next connection walks the library again.
          _queue.clear();
          _queued.clear();
          break;
        }
        if (_queue.isNotEmpty) await Future<void>.delayed(_backgroundPause);
      }
    } finally {
      _running = false;
    }
  }

  /// Reads all of [strategyId] into the copy. False when the server did
  /// not answer.
  Future<bool> _keepStrategy(String strategyId) async {
    final scope = ref.read(cloudCopyScopeProvider);
    if (scope == null || ref.read(cloudOfflineProvider)) return false;
    final store = ref.read(cloudStrategyCopyStoreProvider);
    try {
      final askedAt = DateTime.now();
      final snapshot = await ref
          .read(convexStrategyRepositoryProvider)
          .fetchFullSnapshot(strategyId);
      final answer = snapshot.serverAnswer;
      if (answer == null || ref.read(cloudCopyScopeProvider) != scope) {
        return true;
      }
      await store.writeFullSnapshot(
        scope,
        answer,
        askedAt: askedAt,
        arrivedAt: DateTime.now(),
      );
      // Image files are only ever added here, never deleted.
      await ref.read(cloudMediaCacheProvider.notifier).ensureAssetsCached(
            strategyId: strategyId,
            strategyPublicId: strategyId,
            assets: snapshot.assetsById.values.where((asset) =>
                asset.uploadStatus == 'active' &&
                (asset.url?.isNotEmpty ?? false)),
          );
      return true;
    } catch (error, stackTrace) {
      log('Keeping strategy $strategyId offline failed: $error',
          name: 'strategy_copy', error: error, stackTrace: stackTrace);
      if (isTypedConvexNotFoundError(error) ||
          isTypedConvexForbiddenError(error)) {
        // Deleted, or no longer shared: nothing of it can be opened.
        await store.deleteStrategy(scope, strategyId);
        return true;
      }
      return !isConvexReadUnanswered(error);
    }
  }

  /// False where nothing is kept (web, or a box that would not open): no
  /// read is made for a copy that can't be written.
  bool get _keepsCopies => ref.read(cloudStrategyCopyStoreProvider)
      is! UnavailableCloudStrategyCopyStore;

  void _reset() {
    _generation += 1;
    _queue.clear();
    _queued.clear();
  }
}

/// Whether the cloud can answer reads for the signed-in account right now.
final _cloudReadyProvider = Provider<bool>((ref) {
  return ref.watch(isCloudWorkspaceAvailableProvider) &&
      !ref.watch(cloudOfflineProvider);
});

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

/// `ref.read` of a widget, a provider or a container.
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// How long a copy of cloud work waits for this device's changes to land.
const cloudWorkSendTimeout = Duration(seconds: 20);

/// This device holds cloud work the server does not have yet, so a copy
/// read from the server would leave out changes the user can see.
class CloudWorkNotSent implements Exception {
  const CloudWorkNotSent({required this.unreadable});

  /// Work saved on this device could not be read, so none of it can be
  /// shown to have landed.
  final bool unreadable;

  @override
  String toString() => 'CloudWorkNotSent(unreadable: $unreadable)';
}

/// What to tell the user when a copy of one cloud strategy was refused;
/// [outcome] says what did not happen ("nothing was exported").
String cloudStrategyCopyRefusal(CloudWorkNotSent error, String outcome) =>
    error.unreadable
        ? "Icarus can't read some cloud changes saved on this device, so "
            '$outcome. Review them, then try again.'
        : "Some changes to this strategy haven't synced yet, so $outcome. "
            'Let them sync, or review them, then try again.';

/// Sends the open page's edits, then waits until this device has nothing
/// left to send to the cloud for [strategyId], or for any strategy of the
/// signed-in account when it is null: no edit queued, in flight, held for
/// review or kept for a strategy deleted elsewhere, and no image to upload.
/// Only then does the server hold everything the user did, so every copy
/// read from the server (an .ica, a backup, a video, a duplicate) waits on
/// this first.
///
/// Throws [CloudWorkNotSent] at once when the work cannot land by waiting
/// (held for review, failed, or unreadable), and when it has not landed
/// within [cloudWorkSendTimeout]. [checkpoint] runs before every check, so
/// a caller can stop the wait by throwing from it.
Future<void> sendCloudWork(
  ProviderReader read, {
  String? strategyId,
  void Function()? checkpoint,
}) async {
  bool covers(String id) => strategyId == null || id == strategyId;

  final open = read(strategyProvider);
  final editorCovered = open.source == StrategySource.cloud &&
      open.strategyId != null &&
      covers(open.strategyId!);
  if (editorCovered) {
    // Queues the open page's edits, text still being typed included. Not
    // forceSaveNow: when there is nothing to send, it leaves the save chip
    // saying syncing.
    await read(strategyPageSessionProvider.notifier).flushCurrentPage();
    // Sends them without waiting on the send here: a stalled request must
    // not hold the copy past the deadline below.
    unawaited(read(strategyOpQueueProvider.notifier).flushNow());
  }

  const step = Duration(milliseconds: 100);
  var waited = Duration.zero;
  // Read from the queues at each check: a save with nothing to send
  // changes no queue state, so nothing listening would hear it finish.
  while (true) {
    checkpoint?.call();
    final ops = read(strategyOpQueueProvider);
    final media = read(cloudMediaUploadQueueProvider);
    if (!ops.outboxIsReliable || !media.outboxIsReliable) {
      throw const CloudWorkNotSent(unreadable: true);
    }
    // Edits on a page a teammate deleted are on screen but in no queue:
    // the page is gone, so they can never be sent.
    if (editorCovered &&
        read(strategyPageSessionProvider).deletedPage != null) {
      throw const CloudWorkNotSent(unreadable: false);
    }
    final unsent = [
      for (final strategy in ops.accountOutbox.strategies.values)
        if (covers(strategy.strategyPublicId) && strategy.workCount > 0)
          strategy,
    ];
    // Kept for a strategy the server no longer has; the user discards it.
    final orphaned = ops.accountOutbox.deletedStrategies.keys.any(covers);
    // The open strategy's queue, which can run ahead of the saved records.
    // One that names no strategy counts too: what it holds is unknown.
    final queueStrategy = ops.strategyPublicId;
    final queueCovered = queueStrategy == null || covers(queueStrategy);
    // The upload queue holds the signed-in account's images only.
    final uploads = [
      for (final job in media.jobs)
        if (covers(job.strategyPublicId)) job,
    ];
    if (unsent.isEmpty &&
        !orphaned &&
        uploads.isEmpty &&
        !(queueCovered && (ops.pending.isNotEmpty || ops.isFlushing))) {
      return;
    }
    // Work held for review, kept for a deleted strategy, or failed to
    // upload never lands by waiting.
    final stuck = unsent.any((strategy) => strategy.needsAttention) ||
        orphaned ||
        uploads.any((job) => job.isFailed) ||
        (queueCovered &&
            (ops.pausedByEntityKey.isNotEmpty ||
                ops.attentionByEntityKey.isNotEmpty));
    if (stuck || waited >= cloudWorkSendTimeout) {
      throw const CloudWorkNotSent(unreadable: false);
    }
    await Future<void>.delayed(step);
    waited += step;
  }
}

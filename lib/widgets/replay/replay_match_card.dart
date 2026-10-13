import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/collab/replay_capture_record.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/replay_capture_queue_provider.dart';
import 'package:icarus/replay/replay_capture.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:icarus/replay_view.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/replay/replay_select.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Where the match stands, and the one thing to do with it: capture the
/// moment into a strategy.
class ReplayMatchCard extends ConsumerStatefulWidget {
  const ReplayMatchCard({
    super.key,
    required this.playback,
    required this.map,
    required this.onReturnFromEditor,
  });

  final ReplayPlayback playback;
  final MapValue map;

  /// Called after the captured strategy's editor closes, which leaves its
  /// own map and settings behind.
  final VoidCallback onReturnFromEditor;

  @override
  ConsumerState<ReplayMatchCard> createState() => _ReplayMatchCardState();
}

class _ReplayMatchCardState extends ConsumerState<ReplayMatchCard> {
  late final ReplayCapture _capture = ReplayCapture(
    newStore: ref.read(replayCaptureStoreProvider),
    map: widget.map,
    name: '${replayMapName(widget.map)} replay · '
        '${_dateLabel(widget.playback.document.match.recordedAt)}',
  );

  /// Every strategy this replay captured into, for the captures still on
  /// their way to the cloud.
  final Set<String> _strategyIds = {};

  /// The page Open waits for, while its capture is on its way.
  String? _awaitingPageId;

  String _dateLabel(DateTime? date) =>
      MaterialLocalizations.of(context).formatShortDate(date ?? DateTime.now());

  Future<void> _captureMoment() async {
    final playback = widget.playback;
    playback.pause();
    try {
      // A fresh frame: the saved page must not share objects with the one
      // on screen.
      final frame = playback.frames.frameAt(
        playback.timeMs,
        perspective: playback.perspective,
      );
      final strategy =
          await _capture.capture(frame, pageName: replayMomentLabel(playback));
      _strategyIds.add(strategy.id);
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        "Couldn't capture this moment.",
        error: error,
        stackTrace: stackTrace,
        source: 'ReplayMatchCard.capture',
      );
    }
    if (mounted) setState(() {});
  }

  /// The pages captured into the strategy and not discarded.
  List<String> _keptPageIds(ReplayCaptureQueueState queue) => [
        for (final id in _capture.pageIds)
          if (!queue.discardedPageIds.contains(id)) id,
      ];

  /// Opens the strategy on the page just captured. In the cloud that page
  /// has to get there first: Open waits for it, and a second press stops
  /// waiting.
  Future<void> _openStrategy() async {
    final strategy = _capture.strategy;
    if (strategy == null) return;
    if (strategy.source == StrategySource.local) {
      return _openEditor(strategy, strategy.lastPageId);
    }
    if (_awaitingPageId != null) {
      setState(() => _awaitingPageId = null);
      return;
    }
    final queue = ref.read(replayCaptureQueueProvider);
    final target = _keptPageIds(queue).lastOrNull;
    if (target == null) return;
    final waiting = queue.forStrategy(strategy.id);
    if (waiting.any((capture) => capture.isFailed)) {
      _cantOpen(waiting);
      return;
    }
    if (waiting.any((capture) => capture.pageId == target)) {
      setState(() => _awaitingPageId = target);
      return;
    }
    await _openEditor(strategy, target);
  }

  void _cantOpen(List<ReplayCaptureRecord> waiting) {
    final failure = waiting.firstWhere((capture) => capture.isFailed).failure;
    Settings.showToast(
      message: switch (failure) {
        CaptureFailureKind.deleted =>
          "This strategy was deleted, so it can't be opened.",
        CaptureFailureKind.mapChanged =>
          "This strategy is on another map now, so the replay's captures "
              "can't go there.",
        _ => "A capture couldn't be saved, so the strategy can't open on "
            'it yet. Retry or discard it first.',
      },
      backgroundColor: Settings.tacticalVioletTheme.destructive,
    );
  }

  /// Opens the editor once the page Open waits for has landed.
  void _queueChanged(ReplayCaptureQueueState queue) {
    final target = _awaitingPageId;
    final strategy = _capture.strategy;
    if (target == null || strategy == null) return;
    final waiting = queue.forStrategy(strategy.id);
    if (queue.discardedPageIds.contains(target)) {
      setState(() => _awaitingPageId = null);
    } else if (waiting.any((capture) => capture.isFailed)) {
      setState(() => _awaitingPageId = null);
      _cantOpen(waiting);
    } else if (!waiting.any((capture) => capture.pageId == target)) {
      setState(() => _awaitingPageId = null);
      unawaited(_openEditor(strategy, target));
    }
  }

  Future<void> _openEditor(CapturedStrategy strategy, String pageId) async {
    widget.playback.pause();
    await Navigator.push(
      context,
      StrategyView.route(
        initialStrategyId: strategy.id,
        initialStrategyName: strategy.name,
        initialStrategySource: strategy.source,
        initialMapValue: strategy.map,
        initialIsAttack: strategy.lastPageIsAttack,
        initialPageId: pageId,
        backTooltip: 'Back to replay',
      ),
    );
    if (!mounted) return;
    widget.onReturnFromEditor();
    // The editor may have removed pages, or the whole strategy.
    try {
      await _capture.reload();
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        "Couldn't check the captured strategy.",
        error: error,
        stackTrace: stackTrace,
        source: 'ReplayMatchCard.reload',
        promptUser: false,
      );
    }
    if (mounted) setState(() {});
  }

  Future<void> _retry(List<ReplayCaptureRecord> failed) => ref
      .read(replayCaptureQueueProvider.notifier)
      .retry([for (final capture in failed) capture.id]);

  Future<void> _discard(List<ReplayCaptureRecord> failed) async {
    final mayHaveLanded = await ref
        .read(replayCaptureQueueProvider.notifier)
        .discard([for (final capture in failed) capture.id]);
    if (mayHaveLanded) {
      Settings.showToast(
        message: 'Discarded. It may still appear in your library.',
        backgroundColor: Settings.tacticalVioletTheme.primary,
      );
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    ref.listen(replayCaptureQueueProvider, (_, next) => _queueChanged(next));
    final strategy = _capture.strategy;
    final inCloud = strategy?.source == StrategySource.cloud;
    final queue = ref.watch(replayCaptureQueueProvider);
    // A strategy found deleted or on another map holds none of them now.
    final captured = !inCloud
        ? strategy?.pageCount ?? 0
        : queue.lostStrategyIds.contains(strategy!.id)
            ? 0
            : _keptPageIds(queue).length;
    final unsaved = [
      for (final capture in queue.captures)
        if (_strategyIds.contains(capture.strategyId)) capture,
    ];
    final online =
        inCloud && (ref.watch(convexConnectionProvider).valueOrNull ?? false);
    return Container(
      width: 260,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.border),
      ),
      // The round, the side and the score change a few times a round, not
      // every frame.
      child: ReplaySelect(
        listenable: widget.playback,
        select: () => (
          widget.playback.round,
          _score(widget.playback),
          widget.playback.frame.isAttack,
        ),
        builder: (context, shown) {
          final playback = widget.playback;
          final (round, score, isAttack) = shown;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    round == null ? 'Warmup' : 'Round ${round.index + 1}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isAttack ? 'Attack' : 'Defense',
                    style: theme.textTheme.muted,
                  ),
                  const Spacer(),
                  _Score(ally: score.ally, enemy: score.enemy),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ShadButton(
                      height: 32,
                      onPressed: _captureMoment,
                      leading: const Icon(LucideIcons.camera, size: 16),
                      child: const Text('Capture'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ShadTooltip(
                    builder: (context) =>
                        const Text("See the other team's side"),
                    child: ShadIconButton.outline(
                      width: 32,
                      height: 32,
                      onPressed: () =>
                          playback.perspective = playback.perspective.other,
                      icon: const Icon(LucideIcons.arrowLeftRight, size: 16),
                    ),
                  ),
                ],
              ),
              if (captured > 0) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        captured == 1
                            ? '1 page captured'
                            : '$captured pages captured',
                        style: theme.textTheme.muted,
                      ),
                    ),
                    ShadButton.link(
                      height: 24,
                      padding: EdgeInsets.zero,
                      onPressed: _openStrategy,
                      child: Text(
                        _awaitingPageId == null ? 'Open' : 'Sending…',
                      ),
                    ),
                  ],
                ),
              ],
              if (inCloud && (captured > 0 || unsaved.isNotEmpty))
                _CloudStatus(
                  unsaved: unsaved,
                  online: online,
                  onRetry: _retry,
                  onDiscard: _discard,
                ),
            ],
          );
        },
      ),
    );
  }

  /// Rounds decided by the moment being watched.
  ({int ally, int enemy}) _score(ReplayPlayback playback) {
    var ally = 0;
    var enemy = 0;
    for (final round in playback.document.rounds) {
      if (round.endMs > playback.timeMs) break;
      final winner = round.winningTeam;
      if (winner == null) continue;
      if (winner == playback.perspective) {
        ally++;
      } else {
        enemy++;
      }
    }
    return (ally: ally, enemy: enemy);
  }
}

/// Where this replay's cloud captures are: on their way, saved, or
/// refused, with what can be done about it.
class _CloudStatus extends StatelessWidget {
  const _CloudStatus({
    required this.unsaved,
    required this.online,
    required this.onRetry,
    required this.onDiscard,
  });

  final List<ReplayCaptureRecord> unsaved;
  final bool online;
  final void Function(List<ReplayCaptureRecord>) onRetry;
  final void Function(List<ReplayCaptureRecord>) onDiscard;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final failed = [
      for (final capture in unsaved)
        if (capture.isFailed) capture,
    ];
    final sending = unsaved.length - failed.length;
    if (failed.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          sending == 0
              ? 'Saved to your cloud library'
              : online
                  ? '$sending sending'
                  : '$sending waiting for the connection',
          style: theme.textTheme.muted.copyWith(fontSize: 12),
        ),
      );
    }
    final retryable = [
      for (final capture in failed)
        if (capture.failure == CaptureFailureKind.refused) capture,
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            failed.length == 1
                ? "1 capture couldn't be saved"
                : "${failed.length} captures couldn't be saved",
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.destructive,
            ),
          ),
          Text(
            _reason(failed.first),
            style: theme.textTheme.muted.copyWith(fontSize: 12),
          ),
          Row(
            children: [
              if (retryable.isNotEmpty) ...[
                ShadButton.link(
                  height: 24,
                  padding: EdgeInsets.zero,
                  onPressed: () => onRetry(retryable),
                  child: const Text('Retry'),
                ),
                const SizedBox(width: 12),
              ],
              ShadButton.link(
                height: 24,
                padding: EdgeInsets.zero,
                onPressed: () => onDiscard(failed),
                child: const Text('Discard'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _reason(ReplayCaptureRecord capture) =>
      switch (capture.failure) {
        CaptureFailureKind.deleted => 'Its strategy was deleted.',
        CaptureFailureKind.mapChanged => 'Its strategy is on another map now.',
        _ => 'The cloud refused it.',
      };
}

class _Score extends StatelessWidget {
  const _Score({required this.ally, required this.enemy});

  final int ally;
  final int enemy;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 16, fontWeight: FontWeight.w600);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$ally', style: style.copyWith(color: Settings.allyInk)),
        Text('  –  ',
            style: style.copyWith(
                color: Settings.tacticalVioletTheme.mutedForeground)),
        Text('$enemy', style: style.copyWith(color: Settings.enemyInk)),
      ],
    );
  }
}

/// "Round 7 · 0:42", the time since barriers dropped; "Round 7 · Buy" before.
String replayMomentLabel(ReplayPlayback playback) {
  final round = playback.round;
  if (round == null) return replayClockLabel(playback.timeMs);
  final sincePlay = playback.timeMs - round.playStartMs;
  return 'Round ${round.index + 1} · '
      '${sincePlay < 0 ? 'Buy' : replayClockLabel(sincePlay)}';
}

String replayClockLabel(int ms) {
  final seconds = (ms / 1000).floor().clamp(0, 1 << 30);
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

extension ReplayTeamColors on ReplayTeam {
  Color colorFor(ReplayTeam perspective) =>
      this == perspective ? Settings.allyInk : Settings.enemyInk;
}

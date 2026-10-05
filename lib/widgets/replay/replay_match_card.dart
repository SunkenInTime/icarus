import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/replay/replay_capture.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:icarus/replay_view.dart';
import 'package:icarus/services/app_error_reporter.dart';
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
    createStrategy: (map, name) => ref
        .read(strategyProvider.notifier)
        .createNewStrategy(map: map, name: name),
    map: widget.map,
    name: '${replayMapName(widget.map)} replay · '
        '${_dateLabel(widget.playback.document.match.recordedAt)}',
  );
  bool _capturing = false;

  String _dateLabel(DateTime? date) =>
      MaterialLocalizations.of(context).formatShortDate(date ?? DateTime.now());

  Future<void> _captureMoment() async {
    if (_capturing) return;
    final playback = widget.playback;
    playback.pause();
    setState(() => _capturing = true);
    try {
      // A fresh frame: the saved page must not share objects with the one
      // on screen.
      final frame = playback.frames.frameAt(
        playback.timeMs,
        perspective: playback.perspective,
      );
      await _capture.capture(frame, pageName: replayMomentLabel(playback));
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        "Couldn't capture this moment.",
        error: error,
        stackTrace: stackTrace,
        source: 'ReplayMatchCard.capture',
      );
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  /// Opens the strategy on the page just captured.
  Future<void> _openStrategy() async {
    final strategy = _capture.strategy;
    if (strategy == null) return;
    widget.playback.pause();
    final page = strategy.pages.firstWhere(
      (page) => page.id == _capture.lastPageId,
      orElse: () => strategy.pages.last,
    );
    await Navigator.push(
      context,
      StrategyView.route(
        initialStrategyId: strategy.id,
        initialStrategyName: strategy.name,
        initialMapValue: strategy.mapData,
        initialIsAttack: page.isAttack,
        initialPageId: page.id,
        backTooltip: 'Back to replay',
      ),
    );
    if (!mounted) return;
    widget.onReturnFromEditor();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
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
          final captured = _capture.strategy?.pages.length ?? 0;
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
                      onPressed: _capturing ? null : _captureMoment,
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
                      child: const Text('Open'),
                    ),
                  ],
                ),
              ],
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

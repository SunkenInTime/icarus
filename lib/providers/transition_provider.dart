import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/page_transition/agent_path.dart';
import 'package:icarus/strategy/open_attempt.dart';

const Duration kPageTransitionDuration = Duration(milliseconds: 420);

final class PageSwitch {
  PageSwitch({
    required this.sourcePageId,
    required this.targetPageId,
    required this.attempt,
  });

  final String? sourcePageId;
  final String targetPageId;
  final OpenAttempt attempt;

  bool get isCurrent => attempt.isCurrent;
}

enum TargetDrawings { unread, fadeIn, unchanged }

sealed class PageTransition {
  const PageTransition();

  PageSwitch? get owner => null;
}

final class NoPageTransition extends PageTransition {
  const NoPageTransition();
}

final class PreparingPageTransition extends PageTransition {
  const PreparingPageTransition({
    required this.owner,
    required this.direction,
    required this.leaving,
    required this.agentSize,
    required this.abilitySize,
    required this.fromDoors,
    this.drawings = TargetDrawings.unread,
  });

  @override
  final PageSwitch owner;
  final PageTransitionDirection direction;
  final List<PlacedWidget> leaving;
  final double agentSize;
  final double abilitySize;
  final Set<String> fromDoors;
  final TargetDrawings drawings;
}

final class AnimatingPageTransition extends PageTransition {
  const AnimatingPageTransition({
    required this.owner,
    required this.direction,
    required this.entries,
    required this.agentPaths,
    required this.duration,
    required this.startAgentSize,
    required this.endAgentSize,
    required this.startAbilitySize,
    required this.endAbilitySize,
    required this.fromDoors,
    required this.fadeInDrawings,
    this.progress = 0,
  });

  @override
  final PageSwitch owner;
  final PageTransitionDirection direction;
  final List<PageTransitionEntry> entries;
  final Map<String, AgentTransitionPath> agentPaths;
  final Duration duration;
  final double startAgentSize;
  final double endAgentSize;
  final double startAbilitySize;
  final double endAbilitySize;
  final Set<String> fromDoors;
  final bool fadeInDrawings;
  final double progress;

  AnimatingPageTransition at(double progress) => AnimatingPageTransition(
        owner: owner,
        direction: direction,
        entries: entries,
        agentPaths: agentPaths,
        duration: duration,
        startAgentSize: startAgentSize,
        endAgentSize: endAgentSize,
        startAbilitySize: startAbilitySize,
        endAbilitySize: endAbilitySize,
        fromDoors: fromDoors,
        fadeInDrawings: fadeInDrawings,
        progress: progress,
      );
}

final transitionProvider = NotifierProvider<TransitionProvider, PageTransition>(
    TransitionProvider.new);

class TransitionProvider extends Notifier<PageTransition> {
  @override
  PageTransition build() => const NoPageTransition();

  void prepare(
    PageSwitch owner, {
    required PageTransitionDirection direction,
    required List<PlacedWidget> leaving,
    required double agentSize,
    required double abilitySize,
    Set<String> fromDoors = const {},
  }) {
    state = PreparingPageTransition(
      owner: owner,
      direction: direction,
      leaving: leaving,
      agentSize: agentSize,
      abilitySize: abilitySize,
      fromDoors: fromDoors,
    );
  }

  bool targetRead(PageSwitch owner, {required bool fadeInDrawings}) {
    if (state case final PreparingPageTransition preparing
        when identical(preparing.owner, owner)) {
      state = PreparingPageTransition(
        owner: owner,
        direction: preparing.direction,
        leaving: preparing.leaving,
        agentSize: preparing.agentSize,
        abilitySize: preparing.abilitySize,
        fromDoors: preparing.fromDoors,
        drawings:
            fadeInDrawings ? TargetDrawings.fadeIn : TargetDrawings.unchanged,
      );
      return true;
    }
    return false;
  }

  bool start(
    PageSwitch owner, {
    required List<PageTransitionEntry> entries,
    required Map<String, AgentTransitionPath> agentPaths,
    required double endAgentSize,
    required double endAbilitySize,
    Duration duration = kPageTransitionDuration,
  }) {
    if (state case final PreparingPageTransition preparing
        when identical(preparing.owner, owner) &&
            preparing.drawings != TargetDrawings.unread) {
      state = AnimatingPageTransition(
        owner: owner,
        direction: preparing.direction,
        entries: entries,
        agentPaths: agentPaths,
        duration: duration,
        startAgentSize: preparing.agentSize,
        endAgentSize: endAgentSize,
        startAbilitySize: preparing.abilitySize,
        endAbilitySize: endAbilitySize,
        fromDoors: preparing.fromDoors,
        fadeInDrawings: preparing.drawings == TargetDrawings.fadeIn,
      );
      return true;
    }
    return false;
  }

  void setProgress(PageSwitch owner, double progress) {
    if (state case final AnimatingPageTransition animating
        when identical(animating.owner, owner)) {
      state = animating.at(progress.clamp(0, 1));
    }
  }

  bool finish(PageSwitch owner) {
    if (!identical(state.owner, owner)) return false;
    state = const NoPageTransition();
    return true;
  }

  void clear() => state = const NoPageTransition();
}

final drawingsTransitionOpacityProvider = Provider<double>((ref) {
  return switch (ref.watch(transitionProvider)) {
    PreparingPageTransition(drawings: TargetDrawings.fadeIn) => 0.0,
    AnimatingPageTransition(fadeInDrawings: true, :final progress) =>
      earlyFadeInOpacity(progress),
    _ => 1.0,
  };
});

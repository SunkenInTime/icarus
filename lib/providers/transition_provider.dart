import 'dart:developer';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';

enum PageTransitionPhase { idle, preparing, animating }

const Duration kPageTransitionDuration = Duration(milliseconds: 420);

class PageTransitionState {
  const PageTransitionState({
    required this.active,
    required this.entries,
    required this.progress,
    required this.duration,
    required this.hideView,
    required this.allWidgets,
    required this.direction,
    required this.phase,
    required this.transitionId,
  });
  final bool hideView;
  final bool active;
  final List<PageTransitionEntry> entries;
  final List<PlacedWidget> allWidgets;
  final double progress;
  final Duration duration;
  final PageTransitionDirection direction;
  final PageTransitionPhase phase;
  final int transitionId;

  PageTransitionState copyWith({
    bool? active,
    List<PageTransitionEntry>? entries,
    double? progress,
    Duration? duration,
    bool? hideView,
    List<PlacedWidget>? allWidgets,
    PageTransitionDirection? direction,
    PageTransitionPhase? phase,
    int? transitionId,
  }) =>
      PageTransitionState(
        hideView: hideView ?? this.hideView,
        active: active ?? this.active,
        entries: entries ?? this.entries,
        progress: progress ?? this.progress,
        duration: duration ?? this.duration,
        allWidgets: allWidgets ?? this.allWidgets,
        direction: direction ?? this.direction,
        phase: phase ?? this.phase,
        transitionId: transitionId ?? this.transitionId,
      );

  static const idle = PageTransitionState(
      active: false,
      entries: [],
      progress: 0,
      duration: kPageTransitionDuration,
      hideView: false,
      allWidgets: [],
      direction: PageTransitionDirection.forward,
      phase: PageTransitionPhase.idle,
      transitionId: 0);
}

final transitionProvider =
    NotifierProvider<TransitionProvider, PageTransitionState>(
        TransitionProvider.new);

class TransitionProvider extends Notifier<PageTransitionState> {
  int _nextTransitionId = 1;

  @override
  PageTransitionState build() {
    return PageTransitionState.idle;
  }

  void setProgress(double v) {
    if (!state.active) return;
    state = state.copyWith(progress: v.clamp(0, 1));
  }

  void prepare(List<PlacedWidget> widgets,
      {PageTransitionDirection direction = PageTransitionDirection.forward}) {
    state = state.copyWith(
      allWidgets: widgets,
      hideView: true,
      active: false,
      entries: const [],
      progress: 0,
      phase: PageTransitionPhase.preparing,
      direction: direction,
    );
  }

  void start(List<PageTransitionEntry> entries,
      {Duration duration = kPageTransitionDuration,
      PageTransitionDirection direction = PageTransitionDirection.forward}) {
    state = state.copyWith(
      hideView: true,
      active: true,
      entries: entries,
      progress: 0,
      duration: duration,
      direction: direction,
      phase: PageTransitionPhase.animating,
      transitionId: _nextTransitionId++,
    );
  }

  void setHideView(bool hide) {
    state = state.copyWith(hideView: hide);
  }

  void setAllWidgets(List<PlacedWidget> widgets) {
    state = state.copyWith(allWidgets: widgets);
  }

  void complete() {
    log("Transition Complete Called");
    state = state.copyWith(
      active: false,
      progress: 1,
      hideView: false,
      entries: const [],
      allWidgets: const [],
      phase: PageTransitionPhase.idle,
    );
  }
}

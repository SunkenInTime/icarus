import 'dart:developer';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/transition_data.dart';

class PageTransitionState {
  const PageTransitionState({
    required this.active,
    required this.entries,
    required this.progress,
    required this.duration,
    required this.hideView,
  });
  final bool hideView;
  final bool active;
  final List<PageTransitionEntry> entries;
  final double progress;
  final Duration duration;

  PageTransitionState copyWith({
    bool? active,
    List<PageTransitionEntry>? items,
    double? progress,
    Duration? duration,
    bool? hideView,
  }) =>
      PageTransitionState(
        hideView: hideView ?? this.hideView,
        active: active ?? this.active,
        entries: items ?? entries,
        progress: progress ?? this.progress,
        duration: duration ?? this.duration,
      );

  static const idle = PageTransitionState(
      active: false,
      entries: [],
      progress: 0,
      duration: Duration(seconds: 2),
      hideView: false);
}

final transitionProvider =
    NotifierProvider<TransitionProvider, PageTransitionState>(
        TransitionProvider.new);

class TransitionProvider extends Notifier<PageTransitionState> {
  @override
  PageTransitionState build() {
    return PageTransitionState.idle;
  }

  void setProgress(double v) {
    if (!state.active) return;
    state = state.copyWith(progress: v.clamp(0, 1));
  }

  void start(List<PageTransitionEntry> entries,
      {Duration duration = const Duration(seconds: 2)}) {
    state = PageTransitionState(
      hideView: true,
      active: true,
      entries: entries,
      progress: 0,
      duration: duration,
    );
  }

  void setHideView(bool hide) {
    state = state.copyWith(hideView: hide);
  }

  void complete() {
    log("Transition Complete Called");
    state = state.copyWith(active: false, progress: 1, hideView: false);
  }
}

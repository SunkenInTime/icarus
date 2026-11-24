import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/config/drive_build.dart';

sealed class CanvasShows {
  const CanvasShows();
}

final class ShowsNothing extends CanvasShows {
  const ShowsNothing();
}

final class ShowsPage extends CanvasShows {
  const ShowsPage(this.strategyId, this.pageId);

  final String strategyId;
  final String pageId;
}

final class WaitsToShow extends CanvasShows {
  const WaitsToShow(this.strategyId, this.pageId);

  final String strategyId;
  final String pageId;
}

final class CanvasRefusal {
  const CanvasRefusal({
    required this.what,
    required this.strategyId,
    required this.pageId,
    required this.canvas,
    required this.caller,
  });

  final String what;
  final String strategyId;
  final String? pageId;
  final CanvasShows canvas;
  final String caller;

  @override
  String toString() => '$what for $strategyId page $pageId while the canvas '
      '${switch (canvas) {
        ShowsPage(:final strategyId, :final pageId) =>
          'shows $strategyId page $pageId',
        ShowsNothing() => 'shows nothing',
        WaitsToShow(:final strategyId, :final pageId) =>
          'waits to show $strategyId page $pageId',
      }}, from $caller';
}

String _callerOf(StackTrace trace) {
  for (final line in trace.toString().split('\n')) {
    if (!line.contains('package:icarus/') && !line.contains('icarus')) continue;
    if (line.contains('canvas_shows') ||
        line.contains('flushCurrentPage') ||
        line.contains('_canvasShows')) {
      continue;
    }
    return line.replaceFirst(RegExp(r'^#\d+\s+'), '').trim();
  }
  return 'an unknown caller';
}

final class CanvasShowsNotifier extends Notifier<CanvasShows> {
  final List<CanvasRefusal> refusals = [];

  @override
  CanvasShows build() => const ShowsNothing();

  void refused(String strategyId, String? pageId) {
    if (!driveBuild) return;
    refusals.add(CanvasRefusal(
      what: 'nothing shown',
      strategyId: strategyId,
      pageId: pageId,
      canvas: state,
      caller: _callerOf(StackTrace.current),
    ));
  }

  void emptied() => state = const ShowsNothing();

  void left() => state = const ShowsNothing();

  String? shown(String strategyId, String pageId) {
    final wanted = switch (state) {
      WaitsToShow(strategyId: final wanting, pageId: final page)
          when wanting == strategyId && page != pageId =>
        page,
      _ => null,
    };
    state = ShowsPage(strategyId, pageId);
    return wanted;
  }

  bool shows(String strategyId, String? pageId) => switch (state) {
        ShowsPage(strategyId: final shown, pageId: final page) =>
          shown == strategyId && page == pageId,
        ShowsNothing() || WaitsToShow() => false,
      };

  void want(String strategyId, String pageId) {
    if (driveBuild) {
      refusals.add(CanvasRefusal(
        what: 'switch stayed',
        strategyId: strategyId,
        pageId: pageId,
        canvas: state,
        caller: _callerOf(StackTrace.current),
      ));
    }
    state = WaitsToShow(strategyId, pageId);
  }

  void dropWanted() {
    if (state is WaitsToShow) state = const ShowsNothing();
  }
}

final canvasShowsProvider = NotifierProvider<CanvasShowsNotifier, CanvasShows>(
  CanvasShowsNotifier.new,
);

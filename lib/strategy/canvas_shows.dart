import 'package:flutter_riverpod/flutter_riverpod.dart';

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

final class CanvasShowsNotifier extends Notifier<CanvasShows> {
  @override
  CanvasShows build() => const ShowsNothing();

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

  void want(String strategyId, String pageId) =>
      state = WaitsToShow(strategyId, pageId);

  void dropWanted() {
    if (state is WaitsToShow) state = const ShowsNothing();
  }
}

final canvasShowsProvider = NotifierProvider<CanvasShowsNotifier, CanvasShows>(
  CanvasShowsNotifier.new,
);

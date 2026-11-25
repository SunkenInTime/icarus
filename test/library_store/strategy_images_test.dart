import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/strategy_image.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/strategy/strategy_models.dart';

import '../library_rows/generated_strategies.dart';

StrategyData _strategy(String id) =>
    strategyAsHiveHoldsIt(generatedStrategy(Optionals.set).copyWith(
      id: id,
      pages: [
        _page('$id-p0', 0),
        _page('$id-p1', 1),
        _page('$id-p2', 2),
      ],
    ));

StrategyPage _page(String id, int sortIndex) => generatedPage(
      id: id,
      sortIndex: sortIndex,
      optionals: Optionals.set,
      isAttack: sortIndex.isEven,
    );

LineUpGraph _reorderedSpots(String prefix) {
  final graph = sharedSpotLineups(prefix);
  return LineUpGraph(
    origins: graph.origins,
    landings: graph.landings,
    links: [graph.links[3], ...graph.links.take(3)],
  );
}

StrategyData _withPage(StrategyData strategy, StrategyPage page) =>
    strategy.copyWith(
      pages: [
        for (final each in strategy.pages) each.id == page.id ? page : each,
      ],
    );

String _wordsOf(ReadBack readBack) => switch (readBack) {
      ReadsBackEqual() => 'equal',
      ReadsBackDifferently(:final words) => words,
    };

void main() {
  test(
      'a page whose content changed is read back again, because its cache key '
      'is its whole fingerprint: a page made to read back differently after an '
      'equal check is reported, in the words a check without the cache uses',
      () {
    final images = StrategyImages();
    final strategy = _strategy('changed');
    expect(images.of(strategy).readBack, isA<ReadsBackEqual>());
    expect(images.of(strategy).readBack, isA<ReadsBackEqual>());

    final changed = _withPage(
      strategy,
      strategy.pages[1].copyWith(lineUpGraph: _reorderedSpots('changed-l')),
    );
    final cold = StrategyImages().of(changed).readBack;

    expect(cold, isA<ReadsBackDifferently>());
    expect(_wordsOf(images.of(changed).readBack), _wordsOf(cold));
    expect(_wordsOf(images.of(changed).readBack), _wordsOf(cold));
    expect(images.of(strategy).readBack, isA<ReadsBackEqual>());
  });

  test(
      'a strategy-level change with every page unchanged is checked: pages '
      'saved out of their position order after an equal check are reported',
      () {
    final images = StrategyImages();
    final strategy = _strategy('order');
    expect(images.of(strategy).readBack, isA<ReadsBackEqual>());

    final reordered = strategy.copyWith(
      pages: [strategy.pages[1], strategy.pages[0], strategy.pages[2]],
    );
    final cold = StrategyImages().of(reordered).readBack;

    expect(cold, isA<ReadsBackDifferently>());
    expect(_wordsOf(images.of(reordered).readBack), _wordsOf(cold));
    expect(images.of(strategy).readBack, isA<ReadsBackEqual>());
  });

  test(
      'a page that reads back differently while another strategy shares the '
      'cache is reported for its own strategy only', () {
    final images = StrategyImages();
    final first = _strategy('first');
    final second = _strategy('second');
    final broken = _withPage(
      second,
      second.pages[0].copyWith(lineUpGraph: _reorderedSpots('second-l')),
    );

    expect(images.of(first).readBack, isA<ReadsBackEqual>());
    expect(images.of(broken).readBack, isA<ReadsBackDifferently>());
    expect(images.of(first).readBack, isA<ReadsBackEqual>());
    expect(images.of(second).readBack, isA<ReadsBackEqual>());
  });

  test(
      'as the mirror runs it, the check breaks between frames after the rows '
      'and after each page, and comes to the same answer as in one go',
      () async {
    final strategy = _strategy('between');
    final changed = _withPage(
      strategy,
      strategy.pages[1].copyWith(lineUpGraph: _reorderedSpots('between-l')),
    );
    for (final checked in [strategy, changed]) {
      var breaths = 0;
      final stepped = await StrategyImages().between(checked, () async {
        breaths += 1;
      });
      final whole = StrategyImages().of(checked);
      String words(ReadBack readBack) => switch (readBack) {
            ReadsBackDifferently(:final words) => words,
            ReadsBackEqual() => 'equal',
          };
      expect(words(stepped.readBack), words(whole.readBack));
      expect(breaths, greaterThanOrEqualTo(1 + checked.pages.length));
    }
  });
}

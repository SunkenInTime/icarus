import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/library_store/strategy_image.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/strategy/strategy_models.dart';

import '../library_rows/generated_strategies.dart';

StrategyData _strategy(String id) => generatedStrategy(Optionals.set).copyWith(
      id: id,
      pages: [
        _page('$id-p0', 0),
        _page('$id-p1', 1),
        _page('$id-p2', 2),
      ],
    );

StrategyPage _page(String id, int sortIndex) => generatedPage(
      id: id,
      sortIndex: sortIndex,
      optionals: Optionals.set,
      isAttack: sortIndex.isEven,
    );

LineUpGraph _interleaved(String prefix) {
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
      strategy.pages[1].copyWith(lineUpGraph: _interleaved('changed-l')),
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
      'a page deleted and added again under the same id with other content is '
      'read back again, and reported when it reads back differently', () {
    final images = StrategyImages();
    final strategy = _strategy('readded');
    final last = strategy.pages[2];
    expect(images.of(strategy).readBack, isA<ReadsBackEqual>());

    final deleted = strategy.copyWith(pages: strategy.pages.take(2).toList());
    expect(images.of(deleted).readBack, isA<ReadsBackEqual>());

    final readded = strategy.copyWith(pages: [
      ...deleted.pages,
      last.copyWith(lineUpGraph: _interleaved('readded-l')),
    ]);
    final cold = StrategyImages().of(readded).readBack;

    expect(cold, isA<ReadsBackDifferently>());
    expect(_wordsOf(images.of(readded).readBack), _wordsOf(cold));

    final readdedEqual = strategy.copyWith(pages: [
      ...deleted.pages,
      last.copyWith(name: 'Back again', agentData: const []),
    ]);
    expect(images.of(readdedEqual).readBack, isA<ReadsBackEqual>());
  });

  test(
      'a page that reads back differently while another strategy shares the '
      'cache is reported for its own strategy only', () {
    final images = StrategyImages();
    final first = _strategy('first');
    final second = _strategy('second');
    final broken = _withPage(
      second,
      second.pages[0].copyWith(lineUpGraph: _interleaved('second-l')),
    );

    expect(images.of(first).readBack, isA<ReadsBackEqual>());
    expect(images.of(broken).readBack, isA<ReadsBackDifferently>());
    expect(images.of(first).readBack, isA<ReadsBackEqual>());
    expect(images.of(second).readBack, isA<ReadsBackEqual>());
  });
}

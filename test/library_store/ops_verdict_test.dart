import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/ops_verdict.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

import '../library_rows/generated_strategies.dart';

StrategyRowSet _rows(StrategyData strategy) =>
    switch (strategyToRows(strategyAsHiveHoldsIt(strategy))) {
      StrategyRowsMade(:final rows) => rows,
      StrategyRowsRefused(:final problems) => fail('$problems'),
    };

StrategyPage _page(String id, {LineUpGraph? lineups}) => generatedPage(
      id: id,
      sortIndex: 0,
      optionals: Optionals.set,
      isAttack: true,
      lineups: lineups ?? sharedSpotLineups(id),
    ).copyWith();

StrategyData _strategy(List<StrategyPage> pages) =>
    generatedStrategy(Optionals.unset).copyWith(id: 'classed', pages: pages);

StrategyRowSet _withElements(StrategyRowSet rows, List<ElementRow> elements) =>
    StrategyRowSet(
      strategy: rows.strategy,
      pages: rows.pages,
      settings: rows.settings,
      elements: elements,
      lineupGroups: rows.lineupGroups,
    );

Map<String, ImageRowClass> _classes(List<ImageRowWrite> writes) => {
      for (final write in writes) '${write.kind} ${write.id}': write.rowClass,
    };

void main() {
  test(
      'a stored row is a duplicate-id derived row only when the image holds the same item under another id on the same page; an unrelated extra row stays real',
      () {
    final first = _page('p0');
    final copy = first.copyWith(id: 'p1', sortIndex: 1);
    final image = _rows(_strategy([first, copy]));
    final derived = image.elements
        .whereType<LiveElement>()
        .firstWhere((row) => row.pagePublicId == 'p1');
    final renamed = LiveElement(
      publicId: '${derived.publicId}-stored',
      pagePublicId: derived.pagePublicId,
      payload: derived.payload,
      sortIndex: derived.sortIndex,
      revision: derived.revision,
    );
    final unrelated = LiveElement(
      publicId: 'unrelated',
      pagePublicId: 'p1',
      payload: derived.payload.withData({
        ...derived.payload.data.toJson(),
        'id': 'unrelated',
        'caption': 'Nobody placed this',
      }),
      sortIndex: 99,
      revision: 1,
    );
    final stored = _withElements(image, [
      for (final row in image.elements)
        if (row.publicId != derived.publicId) row,
      renamed,
      unrelated,
    ]);

    final classes = _classes(imageRowWrites(image, stored));
    expect(classes['element ${derived.publicId}'], ImageRowClass.derivedId);
    expect(classes['element ${renamed.publicId}'], ImageRowClass.derivedId);
    expect(classes['element unrelated'], ImageRowClass.real);
  });

  test(
      'a regrouped lineup group is classed as regrouping only when every lineup in it is unchanged; a stale note on a surviving link makes it real',
      () {
    final whole = sharedSpotLineups('pl');
    final withoutA = LineUpGraph(
      origins: whole.origins,
      landings: [
        for (final landing in whole.landings)
          if (landing.id != 'pl-landing-1') landing,
      ],
      links: [
        for (final link in whole.links)
          if (link.id != 'pl-link-a') link,
      ],
    );
    final regrouped = _rows(_strategy([_page('p0', lineups: withoutA)]));
    final stored = StrategyRowSet(
      strategy: regrouped.strategy,
      pages: regrouped.pages,
      settings: regrouped.settings,
      elements: regrouped.elements,
      lineupGroups: [
        for (final row in regrouped.lineupGroups)
          if (row case LiveLineupGroup(publicId: 'pl-link-b'))
            LiveLineupGroup(
              publicId: 'pl-link-a',
              strategyPublicId: row.strategyPublicId,
              pagePublicId: row.pagePublicId,
              payload: row.payload,
              sortIndex: row.sortIndex,
              revision: row.revision,
            )
          else
            row,
      ],
    );
    final staleNote = _rows(_strategy([
      _page(
        'p0',
        lineups: LineUpGraph(
          origins: withoutA.origins,
          landings: withoutA.landings,
          links: [
            for (final link in withoutA.links)
              link.id == 'pl-link-b' ? link.copyWith(notes: 'Changed') : link,
          ],
        ),
      ),
    ]));

    final cleanly = {
      for (final write in imageRowWrites(regrouped, stored))
        if (write.kind == 'lineup group') write.rowClass,
    };
    final withNote = {
      for (final write in imageRowWrites(staleNote, stored))
        if (write.kind == 'lineup group') write.rowClass,
    };
    expect(cleanly, {ImageRowClass.lineupRegrouping});
    expect(withNote, contains(ImageRowClass.real));
  });
}

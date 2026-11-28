import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/l10n/generated/app_localizations.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/strategy/local_library_view.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/widgets/folder_card.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../library_rows/generated_strategies.dart';
import 'store_corpus_test.dart' show corpusLibrary, corpusVariable, storesIn;
import 'tile_parity.dart';

Future<List<String>> _drawnTile(
  WidgetTester tester,
  LocalStrategySummary summary,
) async {
  await tester.pumpWidget(
    ProviderScope(
      child: ShadApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 300,
              child: StrategyTile.local(localStrategy: summary),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return [
    for (final widget in tester.allWidgets)
      switch (widget) {
        Text(:final data?) => 'text $data',
        RichText(:final text) => 'rich ${text.toPlainText()}',
        Image(:final image) => 'image $image',
        _ => null,
      },
  ].nonNulls.toList();
}

StrategySummary? _storeSummaryOf(StrategyData strategy) =>
    switch (strategyToRows(strategyAsHiveHoldsIt(strategy))) {
      StrategyRowsMade(:final rows) => summaryOfRows(rows),
      StrategyRowsRefused() => null,
    };

StrategyData _asHiveDrawsIt(StrategySummary summary, StrategyData strategy) =>
    switch (tileParity(summary, strategy)) {
      TileSame() => strategy,
      TileInGroupOrder() => inGroupOrder(strategy),
      TileInPageOrder()
          when fromStore(summary) == fromHive(inPageOrder(strategy)) =>
        inPageOrder(strategy),
      TileInPageOrder() => inGroupOrder(inPageOrder(strategy)),
      final TileDiffers differs => fail('$differs'),
    };

Future<void> _expectSameTile(
  WidgetTester tester,
  StrategyData strategy,
) async {
  final summary = _storeSummaryOf(strategy);
  if (summary == null) return;
  final hive = await _drawnTile(
    tester,
    LocalStrategySummary.fromHive(
      strategyAsHiveHoldsIt(_asHiveDrawsIt(summary, strategy)),
    ),
  );
  final store =
      await _drawnTile(tester, LocalStrategySummary.fromStore(summary));
  expect(hive, isNotEmpty, reason: strategy.id);
  expect(store, hive, reason: strategy.id);
}

List<StrategyData> _generated() {
  final full = generatedStrategy(Optionals.set);
  final bare = generatedStrategy(Optionals.unset);
  return [
    full,
    bare,
    full.copyWith(
      id: 'all-attack',
      pages: [for (final page in full.pages) page.copyWith(isAttack: true)],
    ),
    full.copyWith(
      id: 'all-defend',
      pages: [for (final page in full.pages) page.copyWith(isAttack: false)],
    ),
    full.copyWith(id: 'one-page', pages: [full.pages.first]),
    bare.copyWith(id: 'no-agents', pages: [
      for (final page in bare.pages) page.copyWith(agentData: const []),
    ]),
  ];
}

void main() {
  testWidgets(
      'a tile drawn from the store summary is the tile Hive draws, for '
      'strategies of every shape', (tester) async {
    for (final strategy in _generated()) {
      await _expectSameTile(tester, strategy);
    }
  });

  test(
      'a folder card made from store summaries shows the counts, maps and '
      'agents one made from Hive does', () {
    final strategies = _generated();
    final folder = Folder(
      name: 'Folder',
      id: 'folder',
      dateCreated: DateTime.utc(2026),
    );
    final fromHive = FolderCardViewData(
      folder: folder,
      strategies: [
        for (final strategy in strategies)
          LocalStrategySummary.fromHive(strategyAsHiveHoldsIt(strategy)),
      ],
      folderCount: 0,
    );
    final fromStore = FolderCardViewData(
      folder: folder,
      strategies: [
        for (final strategy in strategies)
          LocalStrategySummary.fromStore(_storeSummaryOf(strategy)!),
      ],
      folderCount: 0,
    );

    expect(fromStore.strategyCount, fromHive.strategyCount);
    expect(fromStore.mapPeeks, fromHive.mapPeeks);
    expect(fromStore.agentTypes, fromHive.agentTypes);
  });

  final corpus = Platform.environment[corpusVariable];
  testWidgets(
    'every corpus strategy\'s tile drawn from its store summary is the tile '
    'Hive draws',
    skip: corpus == null,
    timeout: const Timeout(Duration(hours: 1)),
    (tester) async {
      final scratch = await tester.runAsync(
        () => Directory.systemTemp.createTemp('icarus-tiles-'),
      );
      addTearDown(
          () => tester.runAsync(() => scratch!.delete(recursive: true)));
      appProviderContainer = ProviderContainer();
      addTearDown(appProviderContainer.dispose);
      if (!Hive.isAdapterRegistered(20)) registerIcarusAdapters(Hive);
      final (strategies, _) = (await tester.runAsync(
        () => corpusLibrary(storesIn(corpus!), scratch!),
      ))!;
      expect(strategies, isNotEmpty);
      for (final strategy in strategies) {
        await _expectSameTile(tester, strategy);
      }
    },
  );
}

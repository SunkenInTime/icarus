import 'dart:convert';

import 'package:icarus/const/maps.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_rows/strategy_comparison.dart';
import 'package:icarus/library_store/strategy_image.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

typedef PageKey = String Function(StrategyData strategy, StrategyPage page);

String fingerprintPageKey(StrategyData strategy, StrategyPage page) =>
    jsonEncode([
      Maps.mapNames[strategy.mapData],
      pageFingerprint(page, strategy.id),
      pagePictureFileNames(page)..sort(),
    ]);

String directPageKey(StrategyData strategy, StrategyPage page) => [
      jsonEncode(Maps.mapNames[strategy.mapData]),
      jsonEncode(page.id),
      jsonEncode(page.sortIndex),
      jsonEncode(page.name),
      jsonEncode(page.isAutoNamed),
      DrawingProvider.objectToJson(page.drawingData),
      AgentProvider.objectToJson(page.agentData),
      AbilityProvider.objectToJson(page.abilityData),
      TextProvider.objectToJson(page.textData),
      PlacedImageProvider.objectToJson(page.imageData, strategy.id),
      UtilityProvider.objectToJson(page.utilityData),
      jsonEncode(page.isAttack),
      StrategySettingsProvider.objectToJson(page.settings),
      jsonEncode(page.lineUpGraph.toJson()),
      jsonEncode(pagePictureFileNames(page)..sort()),
    ].join('\n');

ReadBack readBackInOneGo(
  StrategyData strategy, {
  PageKey pageKey = directPageKey,
}) {
  final StrategyRowSet rows;
  switch (strategyToRows(strategy)) {
    case StrategyRowsRefused():
      return const ReadsBackDifferently('the converter refuses it');
    case StrategyRowsMade(rows: final made):
      rows = made;
  }
  try {
    final outlineEqual = outlineReadsBack(strategyOutline(strategy), rows);
    String? differing;
    for (final page in strategy.pages) {
      if (_pageReadBack(rows, page.id, pageKey) != pageKey(strategy, page)) {
        differing ??= page.id;
      }
    }
    if (!outlineEqual) {
      return const ReadsBackDifferently(
        'its fields, page order or positions read back differently',
      );
    }
    return differing == null
        ? const ReadsBackEqual()
        : ReadsBackDifferently('page $differing reads back differently');
  } on Object catch (error) {
    return ReadsBackDifferently('it cannot be compared: $error');
  }
}

String? _pageReadBack(StrategyRowSet rows, String pageId, PageKey pageKey) =>
    switch (strategyFromRows(rowsAsStored(StrategyRowSet(
      strategy: rows.strategy,
      pages: [if (rows.page(pageId) case final page?) page],
      settings: [if (rows.settingsOf(pageId) case final settings?) settings],
      elements: rows.elementsOn(pageId),
      lineupGroups: rows.lineupGroupsOn(pageId),
    )))) {
      StrategyDataMade(
        strategy: final back,
        :final unreadable,
        :final notInStrategy,
      )
          when unreadable.isEmpty &&
              notInStrategy.isEmpty &&
              back.pages.length == 1 =>
        pageKey(back, back.pages.single),
      StrategyDataMade() || StrategyDataRefused() => null,
    };

String verdictKind(ReadBack readBack) => switch (readBack) {
      ReadsBackEqual() => 'equal',
      ReadsBackDifferently(:final words)
          when words.startsWith('it cannot be compared') =>
        'cannot be compared',
      ReadsBackDifferently(:final words)
          when words == 'the converter refuses it' ||
              words.startsWith('its fields') =>
        words,
      ReadsBackDifferently() => 'differently',
    };

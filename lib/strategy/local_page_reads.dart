import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

final class LocalPageServed {
  LocalPageServed({
    required List<String> pageIds,
    required this.themeProfileId,
    required this.themeOverridePalette,
  }) : pageIds = List.unmodifiable(pageIds);

  final List<String> pageIds;
  final String themeProfileId;
  final MapThemePalette? themeOverridePalette;
}

abstract interface class LocalPageReads {
  int opening(String strategyId);

  void reading(int open, {required bool migrated});

  void openFailed(int open, Object error);

  void openEnded(int open);

  void openedWithoutPage(int open);

  int switching(String strategyId, String pageId);

  void switchFailed(int attempt, Object error);

  void switchEnded(int attempt);

  Future<StrategyEditorPageData?> page(
    String strategyId,
    String pageId, {
    required bool migrated,
  });

  StrategyEditorPageData drawnFromHive(
    String strategyId,
    String pageId,
    StrategyEditorPageData page,
  );

  LocalPageServed? servedWith(StrategyEditorPageData page);

  bool hiveWrittenSinceRead(StrategyEditorPageData page);

  StrategyEditorPageData redrawnFromHive(
    StrategyEditorPageData served,
    StrategyEditorPageData hive,
  );

  void applied(StrategyEditorPageData page);
}

final localPageReadsProvider = Provider<LocalPageReads?>((ref) => null);

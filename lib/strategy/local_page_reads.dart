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
  void opening(String strategyId, {required bool migrated});

  Future<StrategyEditorPageData?> page(
    String strategyId,
    String pageId, {
    required bool migrated,
  });

  LocalPageServed? servedWith(StrategyEditorPageData page);
}

final localPageReadsProvider = Provider<LocalPageReads?>((ref) => null);

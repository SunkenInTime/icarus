import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

/// Whether [agentSize] / [abilitySize] differ across strategy pages, using
/// [liveSettings] for the page matching [activePageId] and persisted
/// [StrategyPage.settings] for all others.
bool markerSizesDifferAcrossPages({
  required StrategyData? strategy,
  required String? activePageId,
  required StrategySettings liveSettings,
}) {
  final pages = strategy?.pages;
  if (pages == null || pages.length < 2) return false;

  final effectiveActiveId = activePageId ?? pages.first.id;

  final firstPage = pages.first;
  final firstSettings =
      firstPage.id == effectiveActiveId ? liveSettings : firstPage.settings;
  var refAgent = firstSettings.agentSize;
  var refAbility = firstSettings.abilitySize;

  for (var i = 1; i < pages.length; i++) {
    final page = pages[i];
    final settings =
        page.id == effectiveActiveId ? liveSettings : page.settings;
    if ((settings.agentSize - refAgent).abs() > 1e-6) return true;
    if ((settings.abilitySize - refAbility).abs() > 1e-6) return true;
  }
  return false;
}

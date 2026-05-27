import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

enum StrategySource { local, cloud }

class StrategyEditorPageData {
  const StrategyEditorPageData({
    required this.pageId,
    required this.pageName,
    required this.isAttack,
    required this.map,
    required this.settings,
    required this.agents,
    required this.abilities,
    required this.drawings,
    required this.texts,
    required this.images,
    required this.utilities,
    required this.lineups,
  });

  final String pageId;
  final String pageName;
  final bool isAttack;
  final MapValue map;
  final StrategySettings settings;
  final List<PlacedAgentNode> agents;
  final List<PlacedAbility> abilities;
  final List<DrawingElement> drawings;
  final List<PlacedText> texts;
  final List<PlacedImage> images;
  final List<PlacedUtility> utilities;
  final List<LineUp> lineups;
}

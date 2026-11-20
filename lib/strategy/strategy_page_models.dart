import 'package:icarus/collab/collab_models.dart';
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
    required this.lineUpGraph,
    required this.unshown,
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
  final LineUpGraph lineUpGraph;
  final UnshownCloudContent unshown;
}

typedef UnshownSettings = ({
  CloudPayload payload,
  StrategySettings shownInstead,
});

class UnshownCloudElement {
  const UnshownCloudElement({
    required this.publicId,
    required this.payload,
    required this.sortIndex,
  });

  final String publicId;
  final CloudPayload payload;
  final int sortIndex;
}

class UnshownCloudContent {
  const UnshownCloudContent({this.elements = const [], this.settings});

  static const none = UnshownCloudContent();

  final List<UnshownCloudElement> elements;
  final UnshownSettings? settings;

  bool get isEmpty => elements.isEmpty && settings == null;
}

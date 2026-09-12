import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';

import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';

class StrategyPage extends HiveObject {
  final String id;
  final int sortIndex;
  final String name;
  // Null means this page predates persisted name provenance. Treat it as
  // custom so structural changes never overwrite a name we cannot classify.
  final bool? isAutoNamed;
  final List<DrawingElement> drawingData;
  final List<PlacedAgentNode> agentData;
  final List<PlacedAbility> abilityData;
  final List<PlacedText> textData;
  final List<PlacedImage> imageData;
  final List<PlacedUtility> utilityData;
  final bool isAttack;
  final List<LineUpOrigin> lineUpOrigins;
  final List<LineUpLanding> lineUpLandings;
  final List<LineUpLink> lineUpLinks;
  @Deprecated('Use lineUpOrigins, lineUpLandings and lineUpLinks instead.')
  final List<LineUpGroup> lineUpGroups;
  @Deprecated('Use lineUpOrigins, lineUpLandings and lineUpLinks instead.')
  final List<LineUp> lineUps;
  final StrategySettings settings;

  /// The graph is the source of truth. `lineUpGroups` and `lineUps` are
  /// projections kept for readers that predate it, and legacy input is
  /// upgraded to the graph the moment a page is built.
  factory StrategyPage({
    required String id,
    required String name,
    bool? isAutoNamed,
    required List<DrawingElement> drawingData,
    required List<PlacedAgentNode> agentData,
    required List<PlacedAbility> abilityData,
    required List<PlacedText> textData,
    required List<PlacedImage> imageData,
    required List<PlacedUtility> utilityData,
    required int sortIndex,
    required bool isAttack,
    required StrategySettings settings,
    List<LineUpOrigin> lineUpOrigins = const [],
    List<LineUpLanding> lineUpLandings = const [],
    List<LineUpLink> lineUpLinks = const [],
    @Deprecated('Use lineUpOrigins, lineUpLandings and lineUpLinks instead')
    List<LineUpGroup> lineUpGroups = const [],
    @Deprecated('Use lineUpOrigins, lineUpLandings and lineUpLinks instead')
    List<LineUp> lineUps = const [],
  }) {
    var graph = LineUpGraph(
      origins: lineUpOrigins,
      landings: lineUpLandings,
      links: lineUpLinks,
    );
    if (graph.isEmpty) {
      graph = lineUpGroups.isNotEmpty
          ? LineUpGraph.fromLegacyGroups(lineUpGroups)
          : LineUpGraph.fromLegacyLineUps(lineUps);
    }
    graph = graph.deepCopy();
    final legacyGroups = graph.toLegacyGroups();

    return StrategyPage._(
      id: id,
      name: name,
      isAutoNamed: isAutoNamed,
      drawingData: drawingData,
      agentData: agentData,
      abilityData: abilityData,
      textData: textData,
      imageData: imageData,
      utilityData: utilityData,
      sortIndex: sortIndex,
      isAttack: isAttack,
      settings: settings,
      lineUpOrigins: graph.origins,
      lineUpLandings: graph.landings,
      lineUpLinks: graph.links,
      lineUpGroups: legacyGroups,
      lineUps: _legacyLineUpsFromGroups(legacyGroups),
    );
  }

  StrategyPage._({
    required this.id,
    required this.name,
    required this.isAutoNamed,
    required this.drawingData,
    required this.agentData,
    required this.abilityData,
    required this.textData,
    required this.imageData,
    required this.utilityData,
    required this.sortIndex,
    required this.isAttack,
    required this.settings,
    required this.lineUpOrigins,
    required this.lineUpLandings,
    required this.lineUpLinks,
    required this.lineUpGroups,
    required this.lineUps,
  });

  static List<LineUp> _legacyLineUpsFromGroups(List<LineUpGroup> groups) {
    return [
      for (final group in groups)
        ...group.items.map(
          (item) => LineUp(
            id: item.id,
            agent: group.agent.copyWith(lineUpID: group.id),
            ability: item.ability.copyWith(lineUpID: group.id),
            youtubeLink: item.youtubeLink,
            notes: item.notes,
            images: item.images.map((image) => image.copyWith()).toList(),
          ),
        ),
    ];
  }

  LineUpGraph get lineUpGraph => LineUpGraph(
        origins: lineUpOrigins,
        landings: lineUpLandings,
        links: lineUpLinks,
      );

  StrategyPage copyWith({
    String? id,
    int? sortIndex,
    String? name,
    bool? isAutoNamed,
    List<DrawingElement>? drawingData,
    List<PlacedAgentNode>? agentData,
    List<PlacedAbility>? abilityData,
    List<PlacedText>? textData,
    List<PlacedImage>? imageData,
    List<PlacedUtility>? utilityData,
    bool? isAttack,
    StrategySettings? settings,
    LineUpGraph? lineUpGraph,
    @Deprecated('Use lineUpGraph instead') List<LineUpGroup>? lineUpGroups,
  }) {
    final resolvedGraph = lineUpGraph ??
        (lineUpGroups != null
            ? LineUpGraph.fromLegacyGroups(lineUpGroups)
            : this.lineUpGraph);

    return StrategyPage(
      id: id ?? this.id,
      sortIndex: sortIndex ?? this.sortIndex,
      name: name ?? this.name,
      isAutoNamed: isAutoNamed ?? this.isAutoNamed,
      drawingData: DrawingProvider.fromJson(
          DrawingProvider.objectToJson(drawingData ?? this.drawingData)),
      agentData: AgentProvider.fromJson(AgentProvider.objectToJson(
        agentData ?? this.agentData,
      )),
      abilityData: AbilityProvider.fromJson(AbilityProvider.objectToJson(
        abilityData ?? this.abilityData,
      )),
      textData: TextProvider.fromJson(TextProvider.objectToJson(
        textData ?? this.textData,
      )),
      imageData: PlacedImageProvider.deepCopyWith(imageData ?? this.imageData),
      utilityData: UtilityProvider.fromJson(UtilityProvider.objectToJson(
        utilityData ?? this.utilityData,
      )),
      settings: settings?.copyWith() ?? this.settings.copyWith(),
      isAttack: isAttack ?? this.isAttack,
      lineUpOrigins: resolvedGraph.origins,
      lineUpLandings: resolvedGraph.landings,
      lineUpLinks: resolvedGraph.links,
    );
  }

  Map<String, dynamic> toJson(String strategyID) {
    String fetchedImageData =
        kIsWeb ? "[]" : PlacedImageProvider.objectToJson(imageData, strategyID);
    final lineUpJson = lineUpGraph.toJson();
    String data = '''
               {
               "id": "$id",
               "sortIndex": "$sortIndex",
               "name": "$name",
               "isAutoNamed": $isAutoNamed,
               "drawingData": ${DrawingProvider.objectToJson(drawingData)},
               "agentData": ${AgentProvider.objectToJson(agentData)},
               "abilityData": ${AbilityProvider.objectToJson(abilityData)},
               "textData": ${TextProvider.objectToJson(textData)},
               "imageData":$fetchedImageData,
               "utilityData": ${UtilityProvider.objectToJson(utilityData)},
               "isAttack": "${isAttack.toString()}",
               "settings": ${StrategySettingsProvider.objectToJson(settings)},
               "lineUpOrigins": ${jsonEncode(lineUpJson['lineUpOrigins'])},
               "lineUpLandings": ${jsonEncode(lineUpJson['lineUpLandings'])},
               "lineUpLinks": ${jsonEncode(lineUpJson['lineUpLinks'])}
               }
             ''';

    final result = jsonDecode(data) as Map<String, dynamic>;
    if (isAutoNamed == null) {
      result.remove('isAutoNamed');
    }
    return result;
  }

  static Future<List<StrategyPage>> listFromJson(
      {required String json,
      required String strategyID,
      required bool isZip}) async {
    List<StrategyPage> pages = [];
    List<dynamic> listJson = jsonDecode(json);

    for (final item in listJson) {
      final page =
          await fromJson(json: item, strategyID: strategyID, isZip: isZip);
      pages.add(page);
    }

    final reindexed = [
      for (var i = 0; i < pages.length; i++) pages[i].copyWith(sortIndex: i),
    ];

    return reindexed;
  }

  static Future<StrategyPage> fromJson(
      {required Map<String, dynamic> json,
      required String strategyID,
      required bool isZip}) async {
    final bool? isAutoNamed;
    if (!json.containsKey('isAutoNamed')) {
      isAutoNamed = null;
    } else if (json['isAutoNamed'] is bool) {
      isAutoNamed = json['isAutoNamed'] as bool;
    } else {
      throw const FormatException(
        'Strategy page isAutoNamed must be a boolean',
      );
    }

    List<PlacedImage> imageData = [];

    if (!kIsWeb) {
      if (isZip) {
        imageData = await PlacedImageProvider.fromJson(
            jsonString: jsonEncode(json['imageData']), strategyID: strategyID);
      } else {
        imageData = await PlacedImageProvider.legacyFromJson(
            jsonString: jsonEncode(json["imageData"] ?? []),
            strategyID: strategyID);
      }
    }

    bool isAttack;
    if (json['isAttack'] == "true") {
      isAttack = true;
    } else {
      isAttack = false;
    }

    final graph = _lineUpGraphFromJson(json);

    return StrategyPage(
      id: json['id'],
      sortIndex: int.parse(json['sortIndex']),
      name: json['name'],
      isAutoNamed: isAutoNamed,
      drawingData: DrawingProvider.fromJson(jsonEncode(json['drawingData'])),
      agentData: AgentProvider.fromJson(jsonEncode(json['agentData'])),
      abilityData: AbilityProvider.fromJson(jsonEncode(json['abilityData'])),
      textData: TextProvider.fromJson(jsonEncode(json['textData'])),
      imageData: imageData,
      utilityData: UtilityProvider.fromJson(jsonEncode(json['utilityData'])),
      isAttack: isAttack,
      settings: StrategySettings.fromJson(json['settings']),
      lineUpOrigins: graph.origins,
      lineUpLandings: graph.landings,
      lineUpLinks: graph.links,
    );
  }

  static LineUpGraph _lineUpGraphFromJson(Map<String, dynamic> json) {
    if (LineUpGraph.hasJson(json)) {
      return LineUpGraph.fromJson(json);
    }
    if (json['lineUpGroups'] != null) {
      return LineUpGraph.fromLegacyGroups(
        LineUpProvider.legacyGroupsFromJson(jsonEncode(json['lineUpGroups'])),
      );
    }
    if (json['lineUpData'] != null) {
      return LineUpGraph.fromLegacyGroups(
        LineUpProvider.legacyGroupsFromLineUpJson(
          jsonEncode(json['lineUpData']),
        ),
      );
    }
    return LineUpGraph.empty;
  }
}

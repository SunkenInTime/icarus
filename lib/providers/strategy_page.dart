import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/image_provider.dart' as PlacedImageProvider;
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';

class StrategyPage extends HiveObject {
  final String id;
  final int sortIndex;
  final String name;
  final List<DrawingElement> drawingData;
  final List<PlacedAgent> agentData;
  final List<PlacedAbility> abilityData;
  final List<PlacedText> textData;
  final List<PlacedImage> imageData;
  final List<PlacedUtility> utilityData;
  final bool isAttack;
  final StrategySettings settings;

  StrategyPage({
    required this.id,
    required this.name,
    required this.drawingData,
    required this.agentData,
    required this.abilityData,
    required this.textData,
    required this.imageData,
    required this.utilityData,
    required this.sortIndex,
    required this.isAttack,
    required this.settings,
  });

  StrategyPage copyWith({
    String? id,
    int? sortIndex,
    String? name,
    List<DrawingElement>? drawingData,
    List<PlacedAgent>? agentData,
    List<PlacedAbility>? abilityData,
    List<PlacedText>? textData,
    List<PlacedImage>? imageData,
    List<PlacedUtility>? utilityData,
    bool? isAttack,
    StrategySettings? settings,
  }) {
    return StrategyPage(
      id: id ?? this.id,
      sortIndex: sortIndex ?? this.sortIndex,
      name: name ?? this.name,
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
      imageData: ImageProvider.deepCopyWith(imageData ?? this.imageData),
      utilityData: UtilityProvider.fromJson(UtilityProvider.objectToJson(
        utilityData ?? this.utilityData,
      )),
      settings: settings?.copyWith() ?? this.settings.copyWith(),
      isAttack: isAttack ?? this.isAttack,
    );
  }

  Map<String, dynamic> toJson(String strategyID) {
    String fetchedImageData =
        kIsWeb ? "[]" : ImageProvider.objectToJson(imageData, strategyID);
    String data = '''
               {
               "id": "$id",
               "sortIndex": "$sortIndex",
               "name": "$name",
               "drawingData": ${DrawingProvider.objectToJson(drawingData)},
               "agentData": ${AgentProvider.objectToJson(agentData)},
               "abilityData": ${AbilityProvider.objectToJson(abilityData)},
               "textData": ${TextProvider.objectToJson(textData)},
               "imageData":$fetchedImageData,
               "utilityData": ${UtilityProvider.objectToJson(utilityData)},
               "isAttack": "${isAttack.toString()}",
               "settings": ${StrategySettingsProvider.objectToJson(settings)}
               }
             ''';

    return jsonDecode(data);
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
    List<PlacedImage> imageData = [];

    if (!kIsWeb) {
      if (isZip) {
        imageData = await ImageProvider.fromJson(
            jsonString: jsonEncode(json['imageData']), strategyID: strategyID);
      } else {
        imageData = await PlacedImageProvider.ImageProvider.legacyFromJson(
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
    return StrategyPage(
      id: json['id'],
      sortIndex: int.parse(json['sortIndex']),
      name: json['name'],
      drawingData: DrawingProvider.fromJson(jsonEncode(json['drawingData'])),
      agentData: AgentProvider.fromJson(jsonEncode(json['agentData'])),
      abilityData: AbilityProvider.fromJson(jsonEncode(json['abilityData'])),
      textData: TextProvider.fromJson(jsonEncode(json['textData'])),
      imageData: imageData,
      utilityData: UtilityProvider.fromJson(jsonEncode(json['utilityData'])),
      isAttack: isAttack,
      settings: StrategySettings.fromJson(json['settings']),
    );
  }
}

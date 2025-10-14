import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:http/retry.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
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
    );
  }
}

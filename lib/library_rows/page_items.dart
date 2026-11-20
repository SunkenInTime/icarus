import 'dart:convert';

import 'package:icarus/collab/cloud_payload_upgrade.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus_library/icarus_library.dart';

sealed class PageItem {
  const PageItem();

  static Decoded<PageItem> decode(ElementPayload payload, MapValue map) {
    final upgraded = upgradeCloudPayload(payload.toJson(), map);
    final data = Map<String, dynamic>.from(upgraded['data'] as Map);
    if (payload.kind == ElementKind.agent &&
        !_agentKinds.contains(data['kind'] ?? PlacedAgentNode.plainKind)) {
      return CouldNotRead(payload.toJson(), 'unknown agent kind');
    }
    try {
      return Read(switch (payload.kind) {
        ElementKind.agent => AgentItem(PlacedAgentNode.fromJson(data)),
        ElementKind.ability => AbilityItem(PlacedAbility.fromJson(data)),
        ElementKind.drawing =>
          DrawingItem(DrawingProvider.elementFromJson(data)),
        ElementKind.text => TextItem(PlacedText.fromJson(data)),
        ElementKind.image => ImageItem(PlacedImage.fromJson(data)),
        ElementKind.utility => UtilityItem(PlacedUtility.fromJson(data)),
      });
    } on FormatException catch (error) {
      return CouldNotRead(payload.toJson(), error.message);
    } on TypeError catch (error) {
      return CouldNotRead(payload.toJson(), '$error');
    } on ArgumentError catch (error) {
      return CouldNotRead(payload.toJson(), '$error');
    } on StateError catch (error) {
      return CouldNotRead(payload.toJson(), error.message);
    } on UnsupportedError catch (error) {
      return CouldNotRead(payload.toJson(), '$error');
    }
  }

  ElementKind get kind;

  String get id;

  Map<String, dynamic> get data;

  Decoded<ElementPayload> get payload {
    final CloudPayload envelope;
    try {
      envelope = cloudElementPayload(kind: kind.name, data: {
        'elementType': kind.name,
        ...data,
      });
    } on JsonUnsupportedObjectError catch (error) {
      return CouldNotRead(null, '$error');
    }
    return Read(
      ElementPayload(
        kind: kind,
        payloadVersion: envelope['payloadVersion'] as int,
        data: envelope['data'] as Map<String, Object?>,
      ),
    );
  }
}

const _agentKinds = {
  PlacedAgentNode.plainKind,
  PlacedAgentNode.viewConeKind,
  PlacedAgentNode.circleKind,
};

bool canReadElementPayload(ElementPayload payload, MapValue map) =>
    PageItem.decode(payload, map) is Read<PageItem>;

final class AgentItem extends PageItem {
  const AgentItem(this.agent);

  final PlacedAgentNode agent;

  @override
  ElementKind get kind => ElementKind.agent;

  @override
  String get id => agent.id;

  @override
  Map<String, dynamic> get data => agent.toJson();
}

final class AbilityItem extends PageItem {
  const AbilityItem(this.ability);

  final PlacedAbility ability;

  @override
  ElementKind get kind => ElementKind.ability;

  @override
  String get id => ability.id;

  @override
  Map<String, dynamic> get data => ability.toJson();
}

final class DrawingItem extends PageItem {
  const DrawingItem(this.drawing);

  final DrawingElement drawing;

  @override
  ElementKind get kind => ElementKind.drawing;

  @override
  String get id => drawing.id;

  @override
  Map<String, dynamic> get data => DrawingProvider.elementToJson(drawing);
}

final class TextItem extends PageItem {
  const TextItem(this.text);

  final PlacedText text;

  @override
  ElementKind get kind => ElementKind.text;

  @override
  String get id => text.id;

  @override
  Map<String, dynamic> get data => text.toJson();
}

final class ImageItem extends PageItem {
  const ImageItem(this.image);

  final PlacedImage image;

  @override
  ElementKind get kind => ElementKind.image;

  @override
  String get id => image.id;

  @override
  Map<String, dynamic> get data => image.toJson();
}

final class UtilityItem extends PageItem {
  const UtilityItem(this.utility);

  final PlacedUtility utility;

  @override
  ElementKind get kind => ElementKind.utility;

  @override
  String get id => utility.id;

  @override
  Map<String, dynamic> get data => utility.toJson();
}

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus_library/icarus_library.dart';

import 'generated_strategies.dart';

const _element = 'element row, payload data';
const _superseded =
    'no home: superseded by pages; not carried, counted as supersededLegacyItems';
const _legacyLineups = 'no home: rebuilt from the lineup graph on read';

const fieldHomes = <String, Map<String, String>>{
  'StrategyData': {
    'id': 'strategy row publicId',
    'name': 'strategy row name',
    'versionNumber':
        'not stored: must be this build\'s version (else NotMigrated or '
            'WrittenByNewerBuild); written back as this build\'s version',
    'mapData': 'strategy row mapData, by map name',
    'folderID': 'strategy row folderPublicId',
    'themeProfileId': 'strategy row themeProfileId',
    'themeOverridePalette':
        'strategy row themeOverridePalette as #RRGGBB; alpha has no home '
            '(PaletteHasTransparency)',
    'pages': 'page rows',
    'createdAt': 'summary createdAt, beside the rows',
    'lastEdited': 'summary lastEdited, beside the rows',
    'drawingData': _superseded,
    'agentData': _superseded,
    'abilityData': _superseded,
    'textData': _superseded,
    'imageData': _superseded,
    'utilityData': _superseded,
    'isAttack': _superseded,
    'strategySettings': _superseded,
  },
  'StrategyPage': {
    'id': 'page row publicId',
    'sortIndex': 'page row sortIndex',
    'name': 'page row name',
    'isAutoNamed': 'page row isAutoNamed',
    'isAttack': 'page row isAttack',
    'settings': 'page settings row',
    'agentData': 'element rows, kind agent; sortIndex 0.. in this order',
    'abilityData': 'element rows, kind ability, after agents',
    'drawingData': 'element rows, kind drawing, after abilities',
    'textData': 'element rows, kind text, after drawings',
    'imageData': 'element rows, kind image, after texts',
    'utilityData': 'element rows, kind utility, after images',
    'lineUpOrigins': 'lineup group rows, data.origins',
    'lineUpLandings': 'lineup group rows, data.landings',
    'lineUpLinks': 'lineup group rows, data.links',
    'lineUps': _legacyLineups,
    'lineUpGroups': _legacyLineups,
  },
  'StrategySettings': {
    'agentSize': 'page settings row settings.agentSize',
    'abilitySize': 'page settings row settings.abilitySize',
    'useNeutralTeamColors': 'page settings row settings.useNeutralTeamColors',
  },
  'Folder': {
    'id': 'folder row publicId',
    'name': 'folder row name',
    'parentID': 'folder row parentFolderPublicId',
    'iconId': 'folder row iconId',
    'color': 'folder row color, by name',
    'customColor': 'folder row customColorValue, as ARGB',
    'dateCreated': 'no home in the row: handed out beside it',
  },
  'PlacedWidget': {
    'id': '$_element.id; the row id too, unless another page took it',
    'isDeleted': '$_element.isDeleted',
    'position': '$_element.position',
    'caption': '$_element.caption',
  },
  'PlacedAgent': {
    'id': '$_element.id',
    'isDeleted': '$_element.isDeleted',
    'position': '$_element.position',
    'caption': '$_element.caption',
    'type': '$_element.type',
    'isAlly': '$_element.isAlly',
    'lineUpID': '$_element.lineUpID',
    'state': '$_element.state',
    'weapon': '$_element.weapon',
  },
  'PlacedViewConeAgent': {
    'id': '$_element.id',
    'isDeleted': '$_element.isDeleted',
    'position': '$_element.position',
    'caption': '$_element.caption',
    'type': '$_element.type',
    'isAlly': '$_element.isAlly',
    'state': '$_element.state',
    'weapon': '$_element.weapon',
    'presetType': '$_element.presetType',
    'rotation': '$_element.rotation',
    'length': '$_element.length',
    'visionElevation': '$_element.visionElevation',
  },
  'PlacedCircleAgent': {
    'id': '$_element.id',
    'isDeleted': '$_element.isDeleted',
    'position': '$_element.position',
    'caption': '$_element.caption',
    'type': '$_element.type',
    'isAlly': '$_element.isAlly',
    'state': '$_element.state',
    'weapon': '$_element.weapon',
    'diameterMeters': '$_element.diameterMeters',
    'colorValue': '$_element.colorValue',
    'opacityPercent': '$_element.opacityPercent',
  },
  'PlacedAbility': {
    'id': '$_element.id',
    'isDeleted': '$_element.isDeleted',
    'position': '$_element.position',
    'caption': '$_element.caption',
    'data': '$_element.data, as {type, index}',
    'isAlly': '$_element.isAlly',
    'rotation': '$_element.rotation',
    'length': '$_element.length',
    'lineUpID': '$_element.lineUpID',
    'armLengthsMeters': '$_element.armLengthsMeters',
    'visualState': '$_element.visualState',
    'wallPath': '$_element.wallPath',
  },
  'AbilityInfo': {
    'type': '$_element.data.type',
    'index': '$_element.data.index',
  },
  'AbilityVisualState': {
    'showRangeOutline': '$_element.visualState.showRangeOutline',
    'showRangeFill': '$_element.visualState.showRangeFill',
    'showInnerOutline': '$_element.visualState.showInnerOutline',
    'showInnerFill': '$_element.visualState.showInnerFill',
    'showVisionCone': '$_element.visualState.showVisionCone',
  },
  'PlacedText': {
    'id': '$_element.id',
    'isDeleted': '$_element.isDeleted',
    'position': '$_element.position',
    'caption': '$_element.caption',
    'text': '$_element.text',
    'size': '$_element.size',
    'fontSize': '$_element.fontSize',
    'sizeVersion': '$_element.sizeVersion',
    'tagColorValue': '$_element.tagColorValue',
  },
  'PlacedImage': {
    'id': '$_element.id',
    'isDeleted': '$_element.isDeleted',
    'position': '$_element.position',
    'caption': '$_element.caption',
    'aspectRatio': '$_element.aspectRatio',
    'scale': '$_element.scale',
    'link': '$_element.link; the move to the cloud drops it',
    'fileExtension': '$_element.fileExtension',
    'tagColorValue': '$_element.tagColorValue',
    'sizeVersion': '$_element.sizeVersion',
    'assetId': '$_element.assetId',
  },
  'PlacedUtility': {
    'id': '$_element.id',
    'isDeleted': '$_element.isDeleted',
    'position': '$_element.position',
    'caption': '$_element.caption',
    'type': '$_element.type',
    'rotation': '$_element.rotation',
    'length': '$_element.length',
    'angle': '$_element.angle',
    'customDiameter': '$_element.customDiameter',
    'customWidth': '$_element.customWidth',
    'customLength': '$_element.customLength',
    'customColorValue': '$_element.customColorValue',
    'customOpacityPercent': '$_element.customOpacityPercent',
    'isAlly': '$_element.isAlly',
    'visionElevation': '$_element.visionElevation',
    'mapDoor': '$_element.mapDoor',
    'isZone': '$_element.isZone, only when true',
  },
  'FreeDrawing': {
    'id': '$_element.id',
    'listOfPoints': '$_element.listOfPoints',
    'colorValue': '$_element.colorValue',
    'thickness': '$_element.thickness',
    'isDotted': '$_element.isDotted',
    'hasArrow': '$_element.hasArrow',
    'boundingBox': '$_element.boundingBox',
    'showTraversalTime': '$_element.showTraversalTime',
    'traversalSpeedProfile': '$_element.traversalSpeedProfile',
    'cachedPolylineLengthUnits':
        'not stored: worked out from listOfPoints when read',
  },
  'Line': {
    'id': '$_element.id',
    'lineStart': '$_element.lineStart',
    'lineEnd': '$_element.lineEnd',
    'colorValue': '$_element.colorValue',
    'thickness': '$_element.thickness',
    'isDotted': '$_element.isDotted',
    'hasArrow': '$_element.hasArrow',
    'boundingBox': '$_element.boundingBox; none comes back worked out',
    'showTraversalTime': '$_element.showTraversalTime',
    'traversalSpeedProfile': '$_element.traversalSpeedProfile',
  },
  'RectangleDrawing': {
    'id': '$_element.id',
    'start': '$_element.start',
    'end': '$_element.end',
    'colorValue': '$_element.colorValue',
    'thickness': '$_element.thickness',
    'isDotted': '$_element.isDotted',
    'hasArrow': '$_element.hasArrow',
    'boundingBox': '$_element.boundingBox; none comes back worked out',
  },
  'EllipseDrawing': {
    'id': '$_element.id',
    'start': '$_element.start',
    'end': '$_element.end',
    'colorValue': '$_element.colorValue',
    'thickness': '$_element.thickness',
    'isDotted': '$_element.isDotted',
    'hasArrow': '$_element.hasArrow',
    'boundingBox': '$_element.boundingBox; none comes back worked out',
  },
  'BoundingBox': {'min': 'boundingBox.min', 'max': 'boundingBox.max'},
  'Offset': {'dx': 'x', 'dy': 'y'},
  'LineUpOrigin': {'id': 'data.origins[].id', 'agent': 'data.origins[].agent'},
  'LineUpLanding': {
    'id': 'data.landings[].id',
    'ability': 'data.landings[].ability',
  },
  'LineUpLink': {
    'id': 'data.links[].id',
    'originId': 'data.links[].originId',
    'landingId': 'data.links[].landingId',
    'name': 'data.links[].name',
    'youtubeLink': 'data.links[].youtubeLink',
    'notes': 'data.links[].notes',
    'images': 'data.links[].images',
  },
  'SimpleImageData': {
    'id': 'data.links[].images[].id',
    'fileExtension': 'data.links[].images[].fileExtension',
  },
  'LineUpGroup': {
    'id': _legacyLineups,
    'agent': _legacyLineups,
    'items': _legacyLineups
  },
  'LineUpItem': {
    'id': _legacyLineups,
    'ability': _legacyLineups,
    'youtubeLink': _legacyLineups,
    'notes': _legacyLineups,
    'images': _legacyLineups,
  },
  'LineUp': {
    'id': _legacyLineups,
    'agent': _legacyLineups,
    'ability': _legacyLineups,
    'youtubeLink': _legacyLineups,
    'notes': _legacyLineups,
    'images': _legacyLineups,
  },
  'MapThemePalette': {
    'baseColorValue': 'themeOverridePalette.base',
    'detailColorValue': 'themeOverridePalette.detail',
    'highlightColorValue': 'themeOverridePalette.highlight',
  },
};

const payloadKeys = <ElementKind, Set<String>>{
  ElementKind.agent: {
    'elementType',
    'kind',
    'id',
    'isDeleted',
    'caption',
    'position',
    'type',
    'isAlly',
    'state',
    'weapon',
    'lineUpID',
    'presetType',
    'rotation',
    'length',
    'visionElevation',
    'diameterMeters',
    'colorValue',
    'opacityPercent',
  },
  ElementKind.ability: {
    'elementType',
    'id',
    'isDeleted',
    'caption',
    'position',
    'data',
    'isAlly',
    'rotation',
    'length',
    'lineUpID',
    'visualState',
    'armLengthsMeters',
    'wallPath',
  },
  ElementKind.drawing: {
    'elementType',
    'type',
    'id',
    'colorValue',
    'thickness',
    'isDotted',
    'hasArrow',
    'boundingBox',
    'listOfPoints',
    'showTraversalTime',
    'traversalSpeedProfile',
    'lineStart',
    'lineEnd',
    'start',
    'end',
  },
  ElementKind.text: {
    'elementType',
    'id',
    'isDeleted',
    'caption',
    'position',
    'text',
    'size',
    'fontSize',
    'sizeVersion',
    'tagColorValue',
  },
  ElementKind.image: {
    'elementType',
    'id',
    'isDeleted',
    'caption',
    'position',
    'aspectRatio',
    'assetId',
    'fileExtension',
    'scale',
    'sizeVersion',
    'tagColorValue',
    'link',
  },
  ElementKind.utility: {
    'elementType',
    'id',
    'isDeleted',
    'caption',
    'position',
    'type',
    'rotation',
    'length',
    'angle',
    'visionElevation',
    'customDiameter',
    'customWidth',
    'customLength',
    'customColorValue',
    'customOpacityPercent',
    'isAlly',
    'mapDoor',
    'isZone',
  },
};

Map<String, Set<String>> generatedAdapterFields() {
  final lines = File('lib/hive/hive_adapters.g.yaml').readAsLinesSync();
  final fields = <String, Set<String>>{};
  String? type;
  var inFields = false;
  for (final line in lines) {
    if (RegExp(r'^  (\w+):$').firstMatch(line) case final match?) {
      type = match[1];
      inFields = false;
    } else if (line == '    fields:') {
      inFields = true;
    } else if (RegExp(r'^      (\w+):$').firstMatch(line) case final match?
        when inFields && type != null) {
      (fields[type] ??= {}).add(match[1]!);
    }
  }
  return fields;
}

Map<String, Set<String>> handWrittenAdapterFields(String file) {
  final source = File(file).readAsStringSync();
  final writes = RegExp(
    r'void write\(BinaryWriter writer, (\w+) obj\) \{(.*?)\n  \}',
    dotAll: true,
  );
  return {
    for (final match in writes.allMatches(source))
      match[1]!: {
        for (final write
            in RegExp(r'\.\.write\((?:obj\.)?(\w+)').allMatches(match[2]!))
          write[1]!,
      },
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => appProviderContainer = ProviderContainer());
  tearDownAll(() => appProviderContainer.dispose());

  test('every field Hive saves of a strategy or folder has a home in rows', () {
    final saved = {
      ...generatedAdapterFields(),
      ...handWrittenAdapterFields('lib/hive/hive_adapters.dart'),
      ...handWrittenAdapterFields('lib/const/agents.dart'),
    };
    for (final MapEntry(key: type, value: homes) in fieldHomes.entries) {
      expect(saved.keys, contains(type));
      expect(saved[type], homes.keys.toSet(), reason: type);
    }
    const notLibrary = {
      'MapValue',
      'AgentType',
      'UtilityType',
      'FolderColor',
      'AgentState',
      'TraversalSpeedProfile',
      'WeaponType',
      'CloudMediaJobState',
      'MapThemeProfile',
      'AppPreferences',
      'StoredFolderIcon',
    };
    expect(
      saved.keys.toSet().difference({...fieldHomes.keys, ...notLibrary}),
      isEmpty,
    );
  });

  test('every key an element payload holds is one the table knows', () {
    final made = strategyToRows(generatedStrategy(Optionals.set));
    final rows = (made as StrategyRowsMade).rows;
    final seen = <ElementKind, Set<String>>{};
    for (final element in rows.elements.cast<LiveElement>()) {
      (seen[element.payload.kind] ??= {}).addAll(element.payload.data.keys);
    }
    expect(seen, payloadKeys);
  });
}

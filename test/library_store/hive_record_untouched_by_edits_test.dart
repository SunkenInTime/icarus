import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:hive_ce/src/binary/binary_writer_impl.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/map_doors.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/traversal_speed.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';

import '../library_rows/generated_strategies.dart';
import 'unit_harness.dart';

final class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

typedef _Edit = void Function(ProviderContainer c, String p);

int _abilityIndex(ProviderContainer c, String id) =>
    c.read(abilityProvider).indexWhere((ability) => ability.id == id);

int _utilityIndex(ProviderContainer c, String id) =>
    c.read(utilityProvider).indexWhere((utility) => utility.id == id);

final _edits = <String, Map<String, _Edit>>{
  'lib/providers/agent_provider.dart': {
    'addAgent': (c, p) => c.read(agentProvider.notifier).addAgent(
          PlacedAgent(
            id: '$p-added',
            type: AgentType.sova,
            position: const Offset(400, 300),
          ),
        ),
    'removeAgent': (c, p) =>
        c.read(agentProvider.notifier).removeAgent('$p-agent'),
    'removeAgentAsAction': (c, p) =>
        c.read(agentProvider.notifier).removeAgentAsAction('$p-agent'),
    'setCaption': (c, p) =>
        c.read(agentProvider.notifier).setCaption('$p-agent', 'changed'),
    'toggleAgentState': (c, p) =>
        c.read(agentProvider.notifier).toggleAgentState('$p-agent'),
    'setWeapon': (c, p) =>
        c.read(agentProvider.notifier).setWeapon('$p-agent', WeaponType.vandal),
    'updatePosition': (c, p) => c
        .read(agentProvider.notifier)
        .updatePosition(const Offset(321, 123), '$p-agent'),
    'duplicateAgentAt': (c, p) => c
        .read(agentProvider.notifier)
        .duplicateAgentAt(sourceId: '$p-agent', position: const Offset(9, 9)),
    'updateViewConeHistory': (c, p) {
      final agents = c.read(agentProvider.notifier)
        ..updateViewConeHistory('$p-cone-agent');
      agents.updateViewConeGeometry(
        id: '$p-cone-agent',
        rotation: 2.5,
        length: 44,
      );
    },
    'updateViewConeGeometry': (c, p) =>
        c.read(agentProvider.notifier).updateViewConeGeometry(
              id: '$p-cone-agent',
              rotation: 2.5,
              length: 44,
            ),
    'updateViewConeElevation': (c, p) => c
        .read(agentProvider.notifier)
        .updateViewConeElevation(id: '$p-cone-agent', elevation: 3),
    'updateCircleGeometry': (c, p) =>
        c.read(agentProvider.notifier).updateCircleGeometry(
              id: '$p-circle-agent',
              diameterMeters: 13,
              colorValue: 0xFF112233,
              opacityPercent: 41,
            ),
    'convertPlainAgentToViewCone': (c, p) =>
        c.read(agentProvider.notifier).convertPlainAgentToViewCone(
              id: '$p-agent',
              presetType: UtilityType.viewCone90,
              rotation: 1,
              length: 30,
            ),
    'convertViewConeAgentToPlain': (c, p) => c
        .read(agentProvider.notifier)
        .convertViewConeAgentToPlain(id: '$p-cone-agent'),
    'convertCircleAgentToPlain': (c, p) => c
        .read(agentProvider.notifier)
        .convertCircleAgentToPlain(id: '$p-circle-agent'),
    'convertPlainAgentToCircle': (c, p) =>
        c.read(agentProvider.notifier).convertPlainAgentToCircle(
              id: '$p-agent',
              diameterMeters: 9,
              colorValue: 0xFF445566,
              opacityPercent: 70,
            ),
  },
  'lib/providers/ability_provider.dart': {
    'addAbility': (c, p) => c.read(abilityProvider.notifier).addAbility(
          c.read(abilityProvider).first.copyWith(id: '$p-added'),
        ),
    'removeAbilityAsAction': (c, p) =>
        c.read(abilityProvider.notifier).removeAbilityAsAction('$p-ability'),
    'removeAbility': (c, p) =>
        c.read(abilityProvider.notifier).removeAbility('$p-ability'),
    'updatePosition': (c, p) => c
        .read(abilityProvider.notifier)
        .updatePosition(const Offset(222, 111), '$p-ability'),
    'duplicateAbilityAt': (c, p) => c
        .read(abilityProvider.notifier)
        .duplicateAbilityAt(
            sourceId: '$p-ability', position: const Offset(8, 8)),
    'updateRotationHistory': (c, p) {
      final index = _abilityIndex(c, '$p-ability');
      c.read(abilityProvider.notifier)
        ..updateRotationHistory(index)
        ..updateRotation(index, 1.75, 33);
    },
    'updateRotation': (c, p) => c
        .read(abilityProvider.notifier)
        .updateRotation(_abilityIndex(c, '$p-ability'), 1.75, 33),
    'updateGeometryHistory': (c, p) {
      final index = _abilityIndex(c, '$p-barrier-mesh');
      c.read(abilityProvider.notifier)
        ..updateGeometryHistory(index)
        ..updateGeometry(index, rotation: 0.5, length: 12);
    },
    'updateGeometry': (c, p) => c
        .read(abilityProvider.notifier)
        .updateGeometry(_abilityIndex(c, '$p-ability'), rotation: 0.5),
    'updateArmLengths': (c, p) => c
        .read(abilityProvider.notifier)
        .updateArmLengths(_abilityIndex(c, '$p-barrier-mesh'), [3, 4, 5, 6]),
    'updateVisualState': (c, p) =>
        c.read(abilityProvider.notifier).updateVisualState(
              _abilityIndex(c, '$p-ability'),
              const AbilityVisualState(showRangeFill: false),
            ),
    'setWallPath': (c, p) => c
        .read(abilityProvider.notifier)
        .setWallPath('$p-high-tide', const [Offset(1, 1), Offset(50, 70)]),
    'setCaption': (c, p) =>
        c.read(abilityProvider.notifier).setCaption('$p-ability', 'changed'),
  },
  'lib/providers/utility_provider.dart': {
    'addUtility': (c, p) => c.read(utilityProvider.notifier).addUtility(
          c.read(utilityProvider).first.copyWith(id: '$p-added'),
        ),
    'removeUtilityAsAction': (c, p) => c
        .read(utilityProvider.notifier)
        .removeUtilityAsAction('$p-utility-spike'),
    'removeUtility': (c, p) =>
        c.read(utilityProvider.notifier).removeUtility('$p-utility-spike'),
    'toggleMapDoor': (c, p) => c
        .read(utilityProvider.notifier)
        .toggleMapDoor(mapDoorsOf(c.read(mapProvider).currentMap).first),
    'updatePosition': (c, p) => c
        .read(utilityProvider.notifier)
        .updatePosition(const Offset(77, 66), '$p-utility-spike'),
    'updateRotationHistory': (c, p) {
      final index = _utilityIndex(c, '$p-utility-viewCone90');
      c.read(utilityProvider.notifier)
        ..updateRotationHistory(index)
        ..updateRotation(index, 0.25, 18);
    },
    'updateRotation': (c, p) => c
        .read(utilityProvider.notifier)
        .updateRotation(_utilityIndex(c, '$p-utility-viewCone90'), 0.25, 18),
    'updateViewConeElevation': (c, p) => c
        .read(utilityProvider.notifier)
        .updateViewConeElevation('$p-utility-viewCone90', 2),
    'updateCustomRectangleSize': (c, p) =>
        c.read(utilityProvider.notifier).updateCustomRectangleSize(
              id: '$p-utility-customRectangle',
              widthMeters: 7,
              lengthMeters: 11,
            ),
    'updateCustomCircleDiameter': (c, p) =>
        c.read(utilityProvider.notifier).updateCustomCircleDiameter(
              id: '$p-utility-customCircle',
              diameterMeters: 6,
            ),
    'updateCustomShapeGeometry': (c, p) =>
        c.read(utilityProvider.notifier).updateCustomShapeGeometry(
              id: '$p-utility-customRectangle',
              position: const Offset(140, 160),
              widthMeters: 5,
            ),
    'setCaption': (c, p) => c
        .read(utilityProvider.notifier)
        .setCaption('$p-utility-spike', 'changed'),
    'updateCustomShapeColor': (c, p) =>
        c.read(utilityProvider.notifier).updateCustomShapeColor(
              id: '$p-utility-customCircle',
              colorValue: 0xFF998877,
            ),
    'updateCustomShapeOpacity': (c, p) =>
        c.read(utilityProvider.notifier).updateCustomShapeOpacity(
              id: '$p-utility-customCircle',
              opacityPercent: 23,
            ),
  },
  'lib/providers/text_provider.dart': {
    'addText': (c, p) => c.read(textProvider.notifier).addText(
          c.read(textProvider).first.copyWith(id: '$p-added'),
        ),
    'removeTextAsAction': (c, p) =>
        c.read(textProvider.notifier).removeTextAsAction('$p-text'),
    'removeText': (c, p) => c.read(textProvider.notifier).removeText('$p-text'),
    'updatePosition': (c, p) => c
        .read(textProvider.notifier)
        .updatePosition(const Offset(55, 44), '$p-text'),
    'commitText': (c, p) =>
        c.read(textProvider.notifier).commitText('$p-text', 'changed'),
    'setCaption': (c, p) =>
        c.read(textProvider.notifier).setCaption('$p-text', 'changed'),
    'updateTagColor': (c, p) =>
        c.read(textProvider.notifier).updateTagColor('$p-text', 0xFF00FF00),
    'resize': (c, p) => c
        .read(textProvider.notifier)
        .resize('$p-text', size: 99, position: const Offset(12, 34)),
  },
  'lib/providers/image_provider.dart': {
    'addImageCopy': (c, p) => c.read(placedImageProvider.notifier).addImageCopy(
          c.read(placedImageProvider).images.first.copyWith(id: '$p-added'),
        ),
    'removeImageAsAction': (c, p) =>
        c.read(placedImageProvider.notifier).removeImageAsAction('$p-image'),
    'removeImage': (c, p) =>
        c.read(placedImageProvider.notifier).removeImage('$p-image'),
    'updatePosition': (c, p) => c
        .read(placedImageProvider.notifier)
        .updatePosition(const Offset(65, 56), '$p-image'),
    'setCaption': (c, p) =>
        c.read(placedImageProvider.notifier).setCaption('$p-image', 'changed'),
    'updateTagColor': (c, p) => c
        .read(placedImageProvider.notifier)
        .updateTagColor('$p-image', 0xFF0000FF),
    'resize': (c, p) => c
        .read(placedImageProvider.notifier)
        .resize('$p-image', scale: 0.7, position: const Offset(21, 43)),
  },
  'lib/providers/drawing_provider.dart': {
    'translateDrawings': (c, p) => c
        .read(drawingProvider.notifier)
        .translateDrawings({'$p-free'}, const Offset(30, 20)),
    'deleteDrawing': (c, p) =>
        c.read(drawingProvider.notifier).deleteDrawing(0),
    'deleteDrawingsById': (c, p) =>
        c.read(drawingProvider.notifier).deleteDrawingsById({'$p-rectangle'}),
    'addDrawings': (c, p) => c.read(drawingProvider.notifier).addDrawings([
          Line(
            lineStart: const Offset(1, 1),
            lineEnd: const Offset(90, 90),
            color: const Color(0xFF123456),
            isDotted: false,
            hasArrow: true,
            id: '$p-added',
          ),
        ]),
    'onErase': (c, p) {
      final free = c
          .read(drawingProvider)
          .elements
          .whereType<FreeDrawing>()
          .firstWhere((drawing) => drawing.id == '$p-free');
      c.read(drawingProvider.notifier).onErase(CoordinateSystem.instance
          .coordinateToScreen(free.listOfPoints.first));
    },
    'startLine': (c, p) {
      final system = CoordinateSystem.instance;
      c.read(drawingProvider.notifier)
        ..startLine(
          const Offset(100, 100),
          system,
          const Color(0xFFFF0000),
          3,
          false,
          true,
          false,
          TraversalSpeed.defaultProfile,
        )
        ..updateCurrentLine(const Offset(300, 200), system)
        ..finishCurrentLine(const Offset(300, 200), system);
    },
  },
  'lib/const/line_provider.dart': {
    'setOriginWeapon': (c, p) => c
        .read(lineUpProvider.notifier)
        .setOriginWeapon(
            c.read(lineUpProvider).origins.first.id, WeaponType.operator),
    'updateLink': (c, p) {
      final link = c.read(lineUpProvider).links.first;
      c
          .read(lineUpProvider.notifier)
          .updateLink(link.copyWith(name: 'changed'));
    },
    'updateOriginAgentPosition': (c, p) => c
        .read(lineUpProvider.notifier)
        .updateOriginAgentPosition(
            c.read(lineUpProvider).origins.first.id, const Offset(33, 22)),
    'updateLandingPosition': (c, p) => c
        .read(lineUpProvider.notifier)
        .updateLandingPosition(
            c.read(lineUpProvider).landings.first.id, const Offset(44, 33)),
    'updateLandingAbilityVisualState': (c, p) =>
        c.read(lineUpProvider.notifier).updateLandingAbilityVisualState(
              landingId: c.read(lineUpProvider).landings.first.id,
              visualState: const AbilityVisualState(showRangeOutline: false),
            ),
    'deleteLink': (c, p) => c
        .read(lineUpProvider.notifier)
        .deleteLink(c.read(lineUpProvider).links.first.id),
    'deleteOrigin': (c, p) => c
        .read(lineUpProvider.notifier)
        .deleteOrigin(c.read(lineUpProvider).origins.first.id),
    'deleteLanding': (c, p) => c
        .read(lineUpProvider.notifier)
        .deleteLanding(c.read(lineUpProvider).landings.first.id),
    'moveEndsFrom': (c, p) {
      final link = c.read(lineUpProvider).links.first;
      final origin = c.read(lineUpProvider).originById(link.originId)!;
      c.read(lineUpProvider.notifier)
        ..startEdit(link.id)
        ..moveEndsFrom(
          {originEndId(origin.id): origin.agent.position},
          const Offset(15, 15),
        )
        ..saveEdit();
    },
    'startEdit': (c, p) {
      final state = c.read(lineUpProvider);
      final link = state.links.first;
      c.read(lineUpProvider.notifier)
        ..startEdit(link.id)
        ..moveEditedOrigin(link.originId, const Offset(70, 80))
        ..moveEditedLanding(link.landingId, const Offset(90, 100))
        ..saveEdit();
    },
    'addCopies': (c, p) => c
        .read(lineUpProvider.notifier)
        .addCopies(sharedSpotLineups('$p-copies')),
  },
};

const _noUndoStep = {
  'lib/providers/agent_provider.dart': {'removeAgent'},
  'lib/providers/ability_provider.dart': {'removeAbility'},
  'lib/providers/utility_provider.dart': {'removeUtility'},
  'lib/providers/text_provider.dart': {
    'removeText',
    'resize',
    'updateTagColor'
  },
  'lib/providers/image_provider.dart': {
    'removeImage',
    'resize',
    'updateTagColor',
  },
};

const _notEdits = <String, Map<String, String>>{
  'lib/providers/agent_provider.dart': {
    'build': 'makes the empty state before a load',
    'undoAction': 'run after every edit here, through the undo stack',
    'redoAction': 'run after every edit here, through the redo stack',
    'toJson': 'reads',
    'toString': 'reads',
    'fromHive': 'the load itself',
    'mergeRemote': 'takes the server\'s items; a cloud strategy is not in Hive',
    'clearAll': 'empties the canvas; changes no item',
  },
  'lib/providers/ability_provider.dart': {
    'build': 'makes the empty state before a load',
    'undoAction': 'run after every edit here, through the undo stack',
    'redoAction': 'run after every edit here, through the redo stack',
    'toJson': 'reads',
    'fromHive': 'the load itself',
    'mergeRemote': 'takes the server\'s items; a cloud strategy is not in Hive',
    'clearAll': 'empties the canvas; changes no item',
  },
  'lib/providers/utility_provider.dart': {
    'takeSnapshot': 'reads',
    'build': 'makes the empty state before a load',
    'undoAction': 'run after every edit here, through the undo stack',
    'redoAction': 'run after every edit here, through the redo stack',
    'toJson': 'reads',
    'toJsonFromData': 'reads',
    'fromHive': 'the load itself',
    'mergeRemote': 'takes the server\'s items; a cloud strategy is not in Hive',
    'clearAll': 'empties the canvas; changes no item',
    'restoreSnapshot': 'puts back copies a snapshot took; changes no item',
  },
  'lib/providers/text_provider.dart': {
    'snapshotForPersistence': 'reads',
    'build': 'makes the empty state before a load',
    'undoAction': 'run after every edit here, through the undo stack',
    'redoAction': 'run after every edit here, through the redo stack',
    'toJson': 'reads',
    'toJsonFromData': 'reads',
    'fromHive': 'the load itself',
    'mergeRemote': 'takes the server\'s items; a cloud strategy is not in Hive',
    'clearAll': 'empties the canvas; changes no item',
  },
  'lib/providers/image_provider.dart': {
    'getImageAspectRatio': 'reads the bytes of a picture',
    'toJson': 'reads',
    'build': 'makes the empty state before a load',
    'undoAction': 'run after every edit here, through the undo stack',
    'redoAction': 'run after every edit here, through the redo stack',
    'fromHive': 'the load itself',
    'mergeRemote': 'takes the server\'s items; a cloud strategy is not in Hive',
    'clearAll': 'empties the canvas; changes no item',
    'addImage': 'a new picture from bytes on disk; changes no item',
    'addImageOnScreen': 'a new picture from bytes on disk; changes no item',
    'saveSecureImage': 'writes picture bytes to disk',
    'discardDraftImage': 'deletes a draft picture file',
    'deleteUnusedImages': 'deletes picture files no item uses',
  },
  'lib/providers/drawing_provider.dart': {
    'build': 'makes the empty state before a load',
    'undoAction': 'run after every edit here, through the undo stack',
    'redoAction': 'run after every edit here, through the redo stack',
    'toJson': 'reads',
    'fromHive': 'the load itself',
    'mergeRemote': 'takes the server\'s items; a cloud strategy is not in Hive',
    'clearAll': 'empties the canvas; changes no item',
    'rebuildAllPaths': 'rebuilds the screen path, which is never saved',
    'startFreeDrawing': 'draws a new item, as startLine does',
    'updateFreeDrawing': 'draws a new item, as startLine does',
    'finishCurrentDrawing': 'draws a new item, as startLine does',
    'finishFreeDrawing': 'draws a new item, as startLine does',
    'startRectangle': 'draws a new item, as startLine does',
    'updateRectangle': 'draws a new item, as startLine does',
    'finishRectangle': 'draws a new item, as startLine does',
    'startEllipse': 'draws a new item, as startLine does',
    'updateEllipse': 'draws a new item, as startLine does',
    'finishEllipse': 'draws a new item, as startLine does',
    'updateCurrentLine': 'part of the startLine edit',
    'finishCurrentLine': 'part of the startLine edit',
  },
  'lib/const/line_provider.dart': {
    'commitPlacement': 'saves the lineup being placed, a new one',
    'originById': 'reads',
    'landingById': 'reads',
    'linkById': 'reads',
    'linksFromOrigin': 'reads',
    'linksToLanding': 'reads',
    'replayEdit': 'an undo or redo step, run after every edit here',
    'replayGraphAction': 'an undo or redo step, run after every edit here',
    'build': 'makes the empty state before a load',
    'undoAction': 'run after every edit here, through the undo stack',
    'redoAction': 'run after every edit here, through the redo stack',
    'fromHive': 'the load itself',
    'mergeRemote':
        'takes the server\'s lineups; a cloud strategy is not in Hive',
    'addRecovered': 'puts back lineups a failed cloud write held',
    'takeOrder': 'orders lineups the server sent',
    'clearAll': 'empties the canvas; changes no lineup',
    'startFresh': 'starts placing a new lineup',
    'startFromOrigin': 'starts placing a new lineup',
    'startToLanding': 'starts placing a new lineup',
    'setDraftAgent': 'the lineup being placed, not yet saved',
    'setDraftAbility': 'the lineup being placed, not yet saved',
    'updateDraftAgentPosition': 'the lineup being placed, not yet saved',
    'setDraftAgentWeapon': 'the lineup being placed, not yet saved',
    'updateDraftAbilityPosition': 'the lineup being placed, not yet saved',
    'updateDraftAbilityGeometry': 'the lineup being placed, not yet saved',
    'clearDraftAbility': 'the lineup being placed, not yet saved',
    'clearPlacement': 'the lineup being placed, not yet saved',
    'moveEditedOrigin': 'part of the startEdit edit',
    'moveEditedLanding': 'part of the startEdit edit',
    'cancelEdit': 'drops an edit under way; changes no lineup',
    'saveEdit': 'part of the startEdit edit',
  },
};

const _notifiers = {
  'lib/providers/agent_provider.dart': 'AgentProvider',
  'lib/providers/ability_provider.dart': 'AbilityProvider',
  'lib/providers/utility_provider.dart': 'UtilityProvider',
  'lib/providers/text_provider.dart': 'TextProvider',
  'lib/providers/image_provider.dart': 'PlacedImageProvider',
  'lib/providers/drawing_provider.dart': 'DrawingProvider',
  'lib/const/line_provider.dart': 'LineUpProvider',
};

Set<String> _publicMethods(String path) {
  final file = File(path).readAsStringSync().replaceAll('\r\n', '\n');
  final start = file.indexOf('class ${_notifiers[path]} extends');
  final source = file.substring(start, file.indexOf('\n}\n', start));
  return {
    for (final match in RegExp(
      r'^  (?!static |return |await |final |const |if |for |switch )'
      r'[A-Za-z][\w<>?, ]*[\w>?] ([a-z][A-Za-z0-9]*)\(',
      multiLine: true,
    ).allMatches(source))
      match.group(1)!,
  };
}

Uint8List _hiveBytes(String id) {
  final writer = BinaryWriterImpl(Hive)
    ..write(Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(id));
  return writer.toBytes();
}

List<String> _items(List<Object?> json) =>
    [for (final item in json) jsonEncode(item)]..sort();

String _canvas(ProviderContainer c) => jsonEncode([
      _items(jsonDecode(AgentProvider.objectToJson(c.read(agentProvider)))),
      _items(jsonDecode(AbilityProvider.objectToJson(c.read(abilityProvider)))),
      _items(jsonDecode(UtilityProvider.objectToJson(c.read(utilityProvider)))),
      _items(jsonDecode(TextProvider.objectToJson(c.read(textProvider)))),
      _items([
        for (final image in c.read(placedImageProvider).images) image.toJson()
      ]),
      _items(jsonDecode(
          DrawingProvider.objectToJson(c.read(drawingProvider).elements))),
      _items(c.read(lineUpProvider).origins.map((o) => o.toJson()).toList()),
      _items(c.read(lineUpProvider).landings.map((l) => l.toJson()).toList()),
      _items(c.read(lineUpProvider).links.map((l) => l.toJson()).toList()),
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  setUpAll(() {
    container = ProviderContainer(
      overrides: [authProvider.overrideWith(_SignedOut.new)],
    );
    appProviderContainer = container;
  });
  setUp(() async => openUnitHive());
  tearDown(() async => Hive.close());

  test(
      'every public method of the item providers is an edit below, or says '
      'why it is not one', () {
    for (final path in _edits.keys) {
      expect(
        _publicMethods(path),
        {..._edits[path]!.keys, ..._notEdits[path]!.keys},
        reason: path,
      );
    }
  });

  var opened = 0;
  for (final MapEntry(key: path, value: edits) in _edits.entries) {
    for (final MapEntry(key: name, value: edit) in edits.entries) {
      test(
          '${path.split('/').last} $name, then undo and redo, leaves the '
          'record Hive holds for the strategy byte for byte as it was',
          () async {
        opened += 1;
        final id = 'untouched-$opened';
        final strategy = generatedStrategy(Optionals.set).copyWith(
          id: id,
          pages: [
            generatedPage(
              id: '$id-p0',
              sortIndex: 0,
              optionals: Optionals.set,
              isAttack: true,
              lineups: sharedSpotLineups('$id-l'),
            ),
          ],
        );
        final h = await openInEditor(container, strategy, follow: false);
        addTearDown(h.dispose);
        final held = _hiveBytes(id);
        final shown = _canvas(container);

        final stepsBefore = container.read(actionProvider).length;
        edit(container, '$id-p0');
        await h.settle();
        final steps = container.read(actionProvider).length - stepsBefore;
        final edited = _canvas(container);
        expect(edited, isNot(shown), reason: 'the edit did nothing');
        expect(_hiveBytes(id), held, reason: 'after the edit');
        expect(steps == 0, _noUndoStep[path]?.contains(name) ?? false,
            reason: '$steps undo steps recorded');

        for (var step = 0; step < (steps == 0 ? 1 : steps); step++) {
          container.read(actionProvider.notifier).undoAction();
          await h.settle();
          expect(_hiveBytes(id), held, reason: 'after undo');
        }
        expect(_canvas(container), steps == 0 ? edited : shown,
            reason: steps == 0
                ? 'undo undid an edit that records no undo step'
                : 'undo did not undo');

        for (var step = 0; step < (steps == 0 ? 1 : steps); step++) {
          container.read(actionProvider.notifier).redoAction();
          await h.settle();
          expect(_hiveBytes(id), held, reason: 'after redo');
        }
        expect(_canvas(container), edited, reason: 'redo did not redo');
      });
    }
  }
}

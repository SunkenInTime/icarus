import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('seed an empty isolated store for main app verification', () async {
    final target = Platform.environment['ICARUS_GALLERY_STORE']!;
    final fixtures = Platform.environment['ICARUS_WALKING_FIXTURES']!;
    final directory = Directory(target);
    if (directory.existsSync() && directory.listSync().isNotEmpty) {
      throw StateError('Gallery seed requires an empty directory.');
    }
    directory.createSync(recursive: true);
    final coordinates = CoordinateSystem(playAreaSize: const Size(1600, 900));
    Hive.init(target);
    registerIcarusAdapters(Hive);
    final box = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    for (final map in [MapValue.split, MapValue.fracture, MapValue.lotus]) {
      final fixture = jsonDecode(
          File('$fixtures/${map.name}/walking-144hz.json').readAsStringSync());
      final pages = <StrategyPage>[];
      for (var page = 0; page < 3; page++) {
        final frame = fixture['frames'][page == 1 ? 419 : 0];
        final agents = <PlacedAgentNode>[];
        for (var i = 0; i < 10; i++) {
          final origin = frame['positionsCanvas'][i];
          final native = frame['poses'][i];
          final matrix = fixture['projection']['nativeToCanvas'];
          final dx = matrix[0][0] * native[3] + matrix[0][1] * native[4];
          final dy = matrix[1][0] * native[3] + matrix[1][1] * native[4];
          agents.add(PlacedViewConeAgent(
              type: AgentType.values[i],
              id: 'cone-$i',
              position: Offset(origin[0], origin[1]) -
                  coordinates.virtualOffsetToWorld(const Offset(
                      Settings.agentSize / 2, Settings.agentSize / 2)),
              presetType: UtilityType.viewCone180,
              rotation: math.atan2(dy, dx) + math.pi / 2,
              length: 361 * .831,
              visionElevation: null));
        }
        pages.add(StrategyPage(
            id: '${map.name}-$page',
            name: ['Standing', 'Walking', 'Defense'][page],
            drawingData: [],
            agentData: agents,
            abilityData: [],
            textData: [],
            imageData: [],
            utilityData: [],
            sortIndex: page,
            isAttack: page != 2,
            settings: StrategySettings()));
      }
      await box.put(
          map.name,
          StrategyData(
              id: map.name,
              name: '${map.name} sightline verification',
              mapData: map,
              versionNumber: Settings.versionNumber,
              lastEdited: DateTime.now(),
              folderID: null,
              pages: pages));
    }
    await Hive.close();
  });
}

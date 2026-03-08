import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/image_scale_policy.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/image_widget_size_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/text_widget_height_provider.dart';
import 'package:icarus/providers/utility_provider.dart';

class _NoopStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() {
    return StrategyState(
      isSaved: true,
      stratName: null,
      id: 'test-strategy',
      storageDirectory: null,
      activePageId: null,
    );
  }

  @override
  void setUnsaved() {
    state = state.copyWith(isSaved: false);
  }
}

ProviderContainer _createContainer() {
  return ProviderContainer(
    overrides: [
      strategyProvider.overrideWith(_NoopStrategyProvider.new),
    ],
  );
}

PlacedUtility _buildUtility(String id) {
  return PlacedUtility(
    type: UtilityType.spike,
    position: const Offset(100, 120),
    id: id,
  );
}

PlacedAgent _buildAgent(String id, Offset position) {
  return PlacedAgent(
    id: id,
    type: AgentType.jett,
    position: position,
  );
}

PlacedAbility _buildAbility(String id) {
  return PlacedAbility(
    id: id,
    position: const Offset(220, 240),
    data: AgentData.agents[AgentType.jett]!.abilities.first,
  );
}

PlacedText _buildText(String id) {
  return PlacedText(
    id: id,
    position: const Offset(300, 320),
  )..text = 'Note';
}

PlacedImage _buildImage(String id) {
  return PlacedImage(
    id: id,
    position: const Offset(360, 380),
    aspectRatio: 1.0,
    scale: ImageScalePolicy.defaultWidth,
    fileExtension: '.png',
  );
}

LineUp _buildLineUp(String id) {
  return LineUp(
    id: id,
    agent: _buildAgent('lineup-agent', const Offset(400, 420)),
    ability: _buildAbility('lineup-ability'),
    youtubeLink: '',
    images: const [],
    notes: 'note',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  group('ActionProvider bulk clear', () {
    test(
        'clearGroupAsAction for utilities is atomic and preserves unrelated groups',
        () {
      final container = _createContainer();
      addTearDown(container.dispose);

      container
          .read(utilityProvider.notifier)
          .addUtility(_buildUtility('utility-1'));
      container.read(agentProvider.notifier).addAgent(
            _buildAgent('agent-1', const Offset(10, 20)),
          );

      container
          .read(actionProvider.notifier)
          .clearGroupAsAction(ActionGroup.utility);

      expect(container.read(utilityProvider), isEmpty);
      expect(container.read(agentProvider), hasLength(1));

      final actions = container.read(actionProvider);
      expect(actions, hasLength(2));
      expect(actions.first.group, ActionGroup.agent);
      expect(actions.last.group, ActionGroup.bulk);
      expect(actions.last.type, ActionType.bulkDeletion);
      expect(
        actions.last.bulkSnapshot!.targetGroups,
        [ActionGroup.utility],
      );
    });

    test(
        'undo bulk clear restores exact action stack and preserved edit history',
        () {
      final container = _createContainer();
      addTearDown(container.dispose);

      container
          .read(utilityProvider.notifier)
          .addUtility(_buildUtility('utility-history'));

      container
          .read(agentProvider.notifier)
          .addAgent(_buildAgent('agent-history', const Offset(40, 50)));
      container
          .read(agentProvider.notifier)
          .updatePosition(const Offset(140, 150), 'agent-history');

      final beforeBulk = [...container.read(actionProvider)];

      container
          .read(actionProvider.notifier)
          .clearGroupAsAction(ActionGroup.agent);

      expect(container.read(agentProvider), isEmpty);

      container.read(actionProvider.notifier).undoAction();

      final restoredActions = container.read(actionProvider);
      expect(restoredActions, hasLength(beforeBulk.length));
      for (var i = 0; i < beforeBulk.length; i++) {
        expect(restoredActions[i].group, beforeBulk[i].group);
        expect(restoredActions[i].type, beforeBulk[i].type);
        expect(restoredActions[i].id, beforeBulk[i].id);
      }

      final restoredAgent = container.read(agentProvider).singleWhere(
            (agent) => agent.id == 'agent-history',
          );
      expect(restoredAgent.position, const Offset(140, 150));

      container.read(actionProvider.notifier).undoAction();

      final revertedAgent = container.read(agentProvider).singleWhere(
            (agent) => agent.id == 'agent-history',
          );
      expect(revertedAgent.position, const Offset(40, 50));
    });

    test('redo reapplies the bulk clear', () {
      final container = _createContainer();
      addTearDown(container.dispose);

      container
          .read(utilityProvider.notifier)
          .addUtility(_buildUtility('utility-2'));

      container
          .read(actionProvider.notifier)
          .clearGroupAsAction(ActionGroup.utility);
      container.read(actionProvider.notifier).undoAction();

      expect(container.read(utilityProvider), hasLength(1));

      container.read(actionProvider.notifier).redoAction();

      expect(container.read(utilityProvider), isEmpty);
      expect(container.read(actionProvider).last.type, ActionType.bulkDeletion);
    });

    test(
        'clearAllAsAction clears and restores every supported group atomically',
        () {
      final container = _createContainer();
      addTearDown(container.dispose);

      container
          .read(agentProvider.notifier)
          .fromHive([_buildAgent('agent-all', const Offset(10, 20))]);
      container
          .read(abilityProvider.notifier)
          .fromHive([_buildAbility('ability-all')]);
      container.read(drawingProvider.notifier).fromHive([
        FreeDrawing(
          id: 'drawing-all',
          color: Colors.red,
          isDotted: false,
          hasArrow: false,
          listOfPoints: const [Offset.zero, Offset(10, 10)],
        ),
      ]);
      container.read(textProvider.notifier).fromHive([_buildText('text-all')]);
      container
          .read(placedImageProvider.notifier)
          .fromHive([_buildImage('image-all')]);
      container
          .read(utilityProvider.notifier)
          .fromHive([_buildUtility('utility-all')]);
      container
          .read(lineUpProvider.notifier)
          .fromHive([_buildLineUp('lineup-all')]);

      container
          .read(imageWidgetSizeProvider.notifier)
          .updateSize('image-all', const Offset(80, 60));
      container
          .read(textWidgetHeightProvider.notifier)
          .updateHeight('text-all', const Offset(120, 44));

      container.read(actionProvider.notifier).clearAllAsAction();

      expect(container.read(agentProvider), isEmpty);
      expect(container.read(abilityProvider), isEmpty);
      expect(container.read(drawingProvider).elements, isEmpty);
      expect(container.read(textProvider), isEmpty);
      expect(container.read(placedImageProvider).images, isEmpty);
      expect(container.read(utilityProvider), isEmpty);
      expect(container.read(lineUpProvider).lineUps, isEmpty);
      expect(
        container.read(imageWidgetSizeProvider.notifier).getSize('image-all'),
        Offset.zero,
      );
      expect(
        container.read(textWidgetHeightProvider.notifier).getOffset('text-all'),
        Offset.zero,
      );
      expect(container.read(actionProvider), hasLength(1));
      expect(
          container.read(actionProvider).single.type, ActionType.bulkDeletion);

      container.read(actionProvider.notifier).undoAction();

      expect(container.read(agentProvider), hasLength(1));
      expect(container.read(abilityProvider), hasLength(1));
      expect(container.read(drawingProvider).elements, hasLength(1));
      expect(container.read(textProvider), hasLength(1));
      expect(container.read(placedImageProvider).images, hasLength(1));
      expect(container.read(utilityProvider), hasLength(1));
      expect(container.read(lineUpProvider).lineUps, hasLength(1));
      expect(
        container.read(imageWidgetSizeProvider.notifier).getSize('image-all'),
        const Offset(80, 60),
      );
      expect(
        container.read(textWidgetHeightProvider.notifier).getOffset('text-all'),
        const Offset(120, 44),
      );
      expect(container.read(actionProvider), isEmpty);
    });

    test('new action after undo invalidates redo for bulk clear', () {
      final container = _createContainer();
      addTearDown(container.dispose);

      container
          .read(utilityProvider.notifier)
          .addUtility(_buildUtility('utility-redo'));
      container
          .read(actionProvider.notifier)
          .clearGroupAsAction(ActionGroup.utility);
      container.read(actionProvider.notifier).undoAction();

      container
          .read(agentProvider.notifier)
          .addAgent(_buildAgent('agent-redo', const Offset(60, 70)));

      container.read(actionProvider.notifier).redoAction();

      expect(
        container.read(utilityProvider).single.id,
        'utility-redo',
      );
      expect(
        container.read(agentProvider).single.id,
        'agent-redo',
      );
      expect(container.read(actionProvider).last.group, ActionGroup.agent);
    });
  });
}

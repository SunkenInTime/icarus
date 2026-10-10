import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/shortcut_info.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/placed_ability_widget.dart';
import 'package:icarus/widgets/global_shortcuts.dart';
import 'package:icarus/widgets/line_up_placer.dart';
import 'package:icarus/widgets/line_up_widget.dart';
import 'package:icarus/widgets/page_transition_overlay.dart';
import 'package:icarus/widgets/rotate_helpers.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _LocalStrategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        strategyId: 'local-strategy',
        strategyName: null,
        source: StrategySource.local,
        storageDirectory: null,
        isOpen: true,
      );

  @override
  void setUnsaved() {}
}

class _AttackMap extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.bind, isAttack: true);

  @override
  void fromHive(MapValue map, bool isAttack) {}
}

class _DefenseMap extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.bind, isAttack: false);

  @override
  void fromHive(MapValue map, bool isAttack) {}
}

/// One placed ability inside the app's shortcut layer.
Future<ProviderContainer> _pumpAbility(
  WidgetTester tester,
  PlacedAbility ability, {
  bool isAttack = true,
}) async {
  // The canvas the coordinate system is laid out for, so a defense-side
  // (mirrored) position is still on screen.
  tester.view
    ..physicalSize = const Size(1920, 1080)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      strategyProvider.overrideWith(_LocalStrategy.new),
      mapProvider.overrideWith(isAttack ? _AttackMap.new : _DefenseMap.new),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });
  container.read(abilityProvider.notifier).fromHive([ability]);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: ShadApp(
        home: Scaffold(
          body: Stack(
            children: [
              PlacedAbilityWidget(
                ability: ability,
                onDragEnd: (_, __) {},
                id: ability.id,
                data: ability,
                rotation: ability.rotation,
                length: ability.length,
              ),
            ],
          ),
        ),
        builder: (context, child) => GlobalShortcuts(child: child!),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _hover(WidgetTester tester, Finder target) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(mouse.removePointer);
  await mouse.addPointer(location: Offset.zero);
  await mouse.moveTo(tester.getCenter(target));
  await tester.pumpAndSettle();
}

Future<void> _press(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  LogicalKeyboardKey? holding,
}) async {
  if (holding != null) await tester.sendKeyDownEvent(holding);
  await tester.sendKeyEvent(key);
  if (holding != null) await tester.sendKeyUpEvent(holding);
  await tester.pumpAndSettle();
}

/// The angle the icon's glyph is drawn at; the tile around it never turns.
double _glyphAngle(WidgetTester tester) {
  final turned = find.descendant(
    of: find.byType(AbilityWidget),
    matching: find.byType(Transform),
  );
  if (turned.evaluate().isEmpty) return 0;
  final matrix = tester.widget<Transform>(turned.first).transform;
  final angle = math.atan2(matrix.entry(1, 0), matrix.entry(0, 0));
  // In [0, 2pi); a hair under a full turn reads as upright.
  final turn = angle % (2 * math.pi);
  return turn > 2 * math.pi - 1e-6 ? 0 : turn;
}

PlacedAbility _plainIcon({double rotation = 0}) {
  final info = AgentData.agents[AgentType.fade]!.abilities.first;
  expect(info.abilityData, isA<BaseAbility>());
  return PlacedAbility(
    id: 'prowler',
    data: info,
    position: const Offset(300, 300),
    rotation: rotation,
  );
}

void main() {
  setUp(() => CoordinateSystem(playAreaSize: const Size(1920, 1080)));

  group('steppedRotation', () {
    test('turns an eighth of a turn each way without wrapping', () {
      expect(steppedRotation(0, clockwise: true), closeTo(math.pi / 4, 1e-9));
      expect(
        steppedRotation(0, clockwise: false),
        closeTo(-math.pi / 4, 1e-9),
      );
      expect(
        steppedRotation(7 * math.pi / 4, clockwise: true),
        closeTo(2 * math.pi, 1e-9),
      );
      // There and back lands on the very angle it started from, so two
      // pages that look the same compare the same.
      for (final start in [0.0, -math.pi / 2, 7 * math.pi / 4]) {
        final back = steppedRotation(
          steppedRotation(start, clockwise: true),
          clockwise: false,
        );
        expect(back, closeTo(start, 1e-9));
      }
    });

    test('an angle between steps lands on the next step', () {
      expect(steppedRotation(0.3, clockwise: true), closeTo(math.pi / 4, 1e-9));
      expect(steppedRotation(0.3, clockwise: false), 0);
      // The handle can leave a negative angle.
      expect(
        steppedRotation(-math.pi / 2, clockwise: true),
        closeTo(-math.pi / 4, 1e-9),
      );
    });
  });

  testWidgets('X turns the hovered icon, Shift+X turns it back, Ctrl+Z undoes',
      (tester) async {
    final container = await _pumpAbility(tester, _plainIcon());
    double stored() => container.read(abilityProvider).single.rotation;

    // Without a hovered item, X does nothing.
    await _press(tester, LogicalKeyboardKey.keyX);
    expect(stored(), 0);

    await _hover(tester, find.byType(AbilityWidget));
    await _press(tester, LogicalKeyboardKey.keyX);
    expect(stored(), closeTo(math.pi / 4, 1e-9));
    expect(_glyphAngle(tester), closeTo(math.pi / 4, 1e-9));

    await _press(tester, LogicalKeyboardKey.keyX);
    expect(stored(), closeTo(math.pi / 2, 1e-9));

    await _press(
      tester,
      LogicalKeyboardKey.keyX,
      holding: LogicalKeyboardKey.shiftLeft,
    );
    expect(stored(), closeTo(math.pi / 4, 1e-9));

    await _press(
      tester,
      LogicalKeyboardKey.keyZ,
      holding: LogicalKeyboardKey.controlLeft,
    );
    expect(stored(), closeTo(math.pi / 2, 1e-9));
    expect(_glyphAngle(tester), closeTo(math.pi / 2, 1e-9));
  });

  testWidgets(
      'an unturned icon stays upright on defense and X turns it '
      'from upright', (tester) async {
    final container = await _pumpAbility(tester, _plainIcon(), isAttack: false);
    expect(_glyphAngle(tester), 0);

    await _hover(tester, find.byType(AbilityWidget));
    await _press(tester, LogicalKeyboardKey.keyX);
    expect(_glyphAngle(tester), closeTo(math.pi / 4, 1e-9));
    // Stored on the map's frame: on attack it points the other way.
    expect(
      container.read(abilityProvider).single.rotation,
      closeTo(5 * math.pi / 4, 1e-9),
    );

    await _press(
      tester,
      LogicalKeyboardKey.keyX,
      holding: LogicalKeyboardKey.shiftLeft,
    );
    expect(_glyphAngle(tester), 0);
    expect(container.read(abilityProvider).single.rotation, isNot(0));
  });

  testWidgets('on defense, Shift+X walks an icon all the way round',
      (tester) async {
    final container = await _pumpAbility(tester, _plainIcon(), isAttack: false);
    await _hover(tester, find.byType(AbilityWidget));
    final seen = <double>[];
    for (var press = 0; press < 8; press++) {
      await _press(
        tester,
        LogicalKeyboardKey.keyX,
        holding: LogicalKeyboardKey.shiftLeft,
      );
      seen.add(_glyphAngle(tester));
    }
    // 315, 270, ..., 45, then upright: every direction, none skipped.
    for (var i = 0; i < 7; i++) {
      expect(seen[i], closeTo((7 - i) * math.pi / 4, 1e-9));
    }
    expect(seen.last, 0);
    // Pointing straight down the defense screen is a turn, not "untouched".
    expect(container.read(abilityProvider).single.rotation, isNot(0));
  });

  testWidgets('X does nothing while a mouse button is held', (tester) async {
    final container = await _pumpAbility(tester, _plainIcon());
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    // Like dragging a rotation handle across the icon: the button goes down
    // elsewhere and the pointer arrives over the icon still held.
    await mouse.addPointer(location: const Offset(10, 10));
    await mouse.down(const Offset(10, 10));
    await tester.pump();
    await mouse.moveTo(tester.getCenter(find.byType(AbilityWidget)));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump();
    expect(container.read(abilityProvider).single.rotation, 0);

    await mouse.up();
    await tester.pumpAndSettle();
    await _press(tester, LogicalKeyboardKey.keyX);
    expect(
      container.read(abilityProvider).single.rotation,
      closeTo(math.pi / 4, 1e-9),
    );
  });

  group('page transitions', () {
    Future<void> pumpMove(
      WidgetTester tester, {
      required bool isAttack,
      required double from,
      required double to,
    }) async {
      final container = ProviderContainer(
        overrides: [
          mapProvider.overrideWith(isAttack ? _AttackMap.new : _DefenseMap.new),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: ShadApp(
            home: Scaffold(
              body: TransitionEntriesLayer(
                entries: [
                  PageTransitionEntry.move(
                    from: _plainIcon(rotation: from),
                    to: _plainIcon(rotation: to),
                  ),
                ],
                agentPaths: const {},
                t: 0.5,
                direction: PageTransitionDirection.forward,
                agentSize: 40,
                abilitySize: 40,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('an unturned icon turns from upright on defense',
        (tester) async {
      // Screen 0 on one page, screen 45 degrees on the next.
      await pumpMove(tester, isAttack: false, from: 0, to: 5 * math.pi / 4);
      expect(_glyphAngle(tester), closeTo(math.pi / 8, 1e-9));
    });

    testWidgets('a turn across the full-turn mark takes the short way',
        (tester) async {
      await pumpMove(
        tester,
        isAttack: true,
        from: 7 * math.pi / 4,
        to: math.pi / 4,
      );
      expect(_glyphAngle(tester), 0);
    });
  });

  test('only plain icons without a vision cone turn their glyph', () {
    expect(drawsGlyphRotation(_plainIcon()), isTrue);
    final camera = PlacedAbility(
      id: 'camera',
      data: AgentData.agents[AgentType.cypher]!.abilities[2],
      position: Offset.zero,
    );
    expect(camera.data.abilityData, isA<BaseAbility>());
    expect(drawsGlyphRotation(camera), isFalse);
  });

  testWidgets('on defense, X turns a camera cone from where it points',
      (tester) async {
    final info = AgentData.agents[AgentType.cypher]!.abilities[2];
    final container = await _pumpAbility(
      tester,
      PlacedAbility(id: 'camera', data: info, position: const Offset(300, 300)),
      isAttack: false,
    );
    await _hover(tester, find.byType(AbilityWidget));
    await _press(tester, LogicalKeyboardKey.keyX);
    // The cone's stored 0 is a real direction, not "unturned".
    expect(
      container.read(abilityProvider).single.rotation,
      closeTo(math.pi / 4, 1e-9),
    );
  });

  testWidgets('a camera with its cone hidden stays upright and ignores X',
      (tester) async {
    final info = AgentData.agents[AgentType.cypher]!.abilities[2];
    final container = await _pumpAbility(
      tester,
      PlacedAbility(
        id: 'camera',
        data: info,
        position: const Offset(300, 300),
        // A cone direction saved while the cone was showing.
        rotation: math.pi / 3,
        visualState: const AbilityVisualState(showVisionCone: false),
      ),
    );
    expect(_glyphAngle(tester), 0);

    await _hover(tester, find.byType(AbilityWidget));
    await _press(tester, LogicalKeyboardKey.keyX);
    expect(container.read(abilityProvider).single.rotation, math.pi / 3);
    expect(_glyphAngle(tester), 0);
  });

  testWidgets('a lineup landing icon stays upright on defense', (tester) async {
    final container = ProviderContainer(
      overrides: [mapProvider.overrideWith(_DefenseMap.new)],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    });
    final lineUp = LineUp(
      id: 'lineup',
      agent: PlacedAgent(
        id: 'lineup-agent',
        type: AgentType.fade,
        position: const Offset(20, 20),
      ),
      ability: _plainIcon().copyWith(id: 'lineup-ability'),
      youtubeLink: '',
      images: const [],
      notes: '',
    );
    container
        .read(lineUpProvider.notifier)
        .fromHive(LineUpGraph.fromLegacyLineUps([lineUp]));
    final landing = container.read(lineUpProvider).landingById(lineUp.id)!;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ShadApp(
          home: Scaffold(
            body: Stack(
              children: [LineUpLandingAbilityWidget(landing: landing)],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_glyphAngle(tester), 0);
  });

  testWidgets('a lineup draft swapped for a plain icon starts upright',
      (tester) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [mapProvider.overrideWith(_AttackMap.new)],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    });
    final lineUps = container.read(lineUpProvider.notifier);
    lineUps.startFresh();
    lineUps.setDraftAgent(
      PlacedAgent(
        id: 'draft-agent',
        type: AgentType.fade,
        position: const Offset(180, 220),
      ),
    );
    // Nightfall, turned by its handle before being swapped out.
    lineUps.setDraftAbility(
      PlacedAbility(
        id: 'nightfall',
        data: AgentData.agents[AgentType.fade]!.abilities.last,
        position: const Offset(300, 300),
        rotation: math.pi / 4,
      ),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ShadApp(
          home: Scaffold(body: LineupPositionWidget()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    lineUps.setDraftAbility(_plainIcon().copyWith(id: 'prowler-draft'));
    await tester.pumpAndSettle();

    expect(find.byType(AbilityWidget), findsOneWidget);
    expect(_glyphAngle(tester), 0);
  });

  test('a key the user already chose beats the new rotate default', () {
    const x = IcarusKeyBinding(trigger: LogicalKeyboardKey.keyX);
    final defaults = ShortcutInfo.globalShortcutsFor(const {});
    expect(
      defaults[x.toActivator(platform: TargetPlatform.windows)],
      isA<RotateHoveredIntent>(),
    );

    final custom = ShortcutInfo.globalShortcutsFor(
      {IcarusShortcutAction.draw.name: x.serialize()},
      platform: TargetPlatform.windows,
    );
    expect(
      custom[x.toActivator(platform: TargetPlatform.windows)],
      isA<ToggleDrawingIntent>(),
    );
  });
}

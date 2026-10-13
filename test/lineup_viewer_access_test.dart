import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/traversal_speed.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/interactive_map.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/pen_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/widgets/dialogs/create_lineup_dialog.dart';
import 'package:icarus/widgets/dialogs/lineup_panel_dialog.dart';
import 'package:icarus/widgets/line_up_media_carousel.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

class _TestActionProvider extends ActionProvider {
  @override
  List<UserAction> build() => [];
}

class _FixedPreferences extends AppPreferencesNotifier {
  @override
  AppPreferences build() => AppPreferences(
        defaultThemeProfileIdForNewStrategies:
            MapThemeProfilesProvider.immutableDefaultProfileId,
      );
}

class _FixedMapProvider extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.bind, isAttack: true);

  @override
  void fromHive(MapValue map, bool isAttack) {}
}

class _EmptyDrawingProvider extends DrawingProvider {
  @override
  DrawingState build() => DrawingState(elements: const []);

  @override
  void rebuildAllPaths(CoordinateSystem coordinateSystem) {}
}

class _FixedPenProvider extends PenProvider {
  @override
  PenState build() => PenState(
        listOfColors: const [],
        color: Colors.white,
        hasArrow: false,
        isDotted: false,
        opacity: 1,
        thickness: 1,
        penMode: PenMode.freeDraw,
        traversalTimeEnabled: false,
        activeTraversalSpeedProfile: TraversalSpeedProfile.running,
        drawingCursor: null,
        erasingCursor: null,
      );
}

LineUpGroup _breachGroup() {
  return LineUpGroup(
    id: 'breach-group',
    agent: PlacedAgent(
      id: 'breach-agent',
      type: AgentType.breach,
      position: const Offset(500, 250),
      isAlly: true,
    ),
    items: [
      LineUpItem(
        id: 'breach-item',
        ability: PlacedAbility(
          id: 'breach-ability',
          data: AgentData.agents[AgentType.breach]!.abilities.first,
          position: const Offset(700, 400),
          isAlly: true,
        ),
      ),
    ],
  );
}

/// The map as a reader with [role] on a cloud strategy sees it: one lineup,
/// and one agent placed on its own.
Future<ProviderContainer> _pumpMap(WidgetTester tester, String role) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1500, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final container = ProviderContainer(
    overrides: [
      actionProvider.overrideWith(_TestActionProvider.new),
      appPreferencesProvider.overrideWith(_FixedPreferences.new),
      mapProvider.overrideWith(_FixedMapProvider.new),
      drawingProvider.overrideWith(_EmptyDrawingProvider.new),
      penProvider.overrideWith(_FixedPenProvider.new),
      effectiveMapThemePaletteProvider.overrideWith(
        (ref) => MapThemeProfilesProvider.immutableDefaultPalette,
      ),
      currentStrategyCapabilitiesProvider.overrideWithValue(
        StrategyCapabilities.fromCloudRole(role),
      ),
    ],
  );
  addTearDown(container.dispose);
  container
      .read(lineUpProvider.notifier)
      .fromHive(LineUpGraph.fromLegacyGroups([_breachGroup()]));
  // Loaded, as the page is: a viewer's own edits are refused.
  container.read(agentProvider.notifier).fromHive([
    PlacedAgent(
      id: 'jett-agent',
      type: AgentType.jett,
      position: const Offset(900, 300),
      isAlly: true,
    ),
  ]);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const ShadApp(home: Scaffold(body: InteractiveMap())),
    ),
  );
  await tester.pump();
  await tester.pump();
  return container;
}

/// The landing's ability icon: the art around it is see-through, and a tap
/// there falls through to the map.
Finder _landingIcon() => find.descendant(
      of: find.byKey(const ValueKey('lineup-ability-breach-item')),
      matching: find.byType(Image),
    );

Finder _originAgent() =>
    find.byKey(const ValueKey('lineup-agent-breach-group'));

Future<void> _hover(WidgetTester tester, Finder finder) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(mouse.removePointer);
  await mouse.addPointer(location: Offset.zero);
  await mouse.moveTo(tester.getCenter(finder));
  await tester.pump();
}

/// The capabilities of the open strategy, changeable mid-test.
final _capabilities = StateProvider<StrategyCapabilities>(
  (ref) => StrategyCapabilities.fullAccess(),
);

/// Who makes each edit in [_lineUpEdits]. A local strategy can always be
/// edited.
final _readers = <String, StrategyCapabilities>{
  'viewer': StrategyCapabilities.fromCloudRole('viewer'),
  'editor': StrategyCapabilities.fromCloudRole('editor'),
  'owner': StrategyCapabilities.fromCloudRole('owner'),
  'local strategy': StrategyCapabilities.fullAccess(),
};

/// One lineup, loaded the way the server's copy is.
ProviderContainer _loadedLineUps(StrategyCapabilities capabilities) {
  final container = ProviderContainer(overrides: [
    actionProvider.overrideWith(_TestActionProvider.new),
    currentStrategyCapabilitiesProvider
        .overrideWith((ref) => ref.watch(_capabilities)),
  ]);
  container.read(_capabilities.notifier).state = capabilities;
  container
      .read(lineUpProvider.notifier)
      .fromHive(LineUpGraph.fromLegacyGroups([_breachGroup()]));
  return container;
}

String _lineUpContent(ProviderContainer container) =>
    jsonEncode(container.read(lineUpProvider).graph.toJson());

/// Each mutator that commits a lineup edit, with an edit that changes the
/// lineup [_loadedLineUps] loads.
final _lineUpEdits = <String, void Function(LineUpProvider lineUps)>{
  'place a lineup': (lineUps) {
    lineUps
      ..startFresh()
      ..setDraftAgent(PlacedAgent(
        id: 'draft-agent',
        type: AgentType.breach,
        position: const Offset(300, 300),
      ))
      ..setDraftAbility(PlacedAbility(
        id: 'draft-ability',
        data: AgentData.agents[AgentType.breach]!.abilities.first,
        position: const Offset(600, 300),
      ))
      ..commitPlacement(name: 'Retake');
  },
  'move a lineup in Edit placement': (lineUps) {
    lineUps
      ..startEdit('breach-item')
      ..moveEditedOrigin('breach-group', const Offset(520, 260))
      ..saveEdit();
  },
  "arm a lineup's agent": (lineUps) =>
      lineUps.setOriginWeapon('breach-group', WeaponType.classic),
  'rename a lineup': (lineUps) => lineUps.updateLink(
        lineUps.linkById('breach-item')!.copyWith(name: 'Retake'),
      ),
  "move a lineup's origin": (lineUps) => lineUps.updateOriginAgentPosition(
        'breach-group',
        const Offset(520, 260),
      ),
  "move a lineup's landing": (lineUps) => lineUps.updateLandingPosition(
        'breach-item',
        const Offset(720, 420),
      ),
  "hide a landing's range": (lineUps) =>
      lineUps.updateLandingAbilityVisualState(
        landingId: 'breach-item',
        visualState: const AbilityVisualState(showRangeFill: false),
      ),
  'delete a lineup': (lineUps) => lineUps.deleteLink('breach-item'),
  'delete an origin': (lineUps) => lineUps.deleteOrigin('breach-group'),
  'delete a landing': (lineUps) => lineUps.deleteLanding('breach-item'),
};

Finder _toast(String text) => find.byWidgetPredicate(
      (widget) => widget is Text && widget.data == text,
      skipOffstage: false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a viewer opens a lineup landing, without its edit buttons',
      (tester) async {
    await _pumpMap(tester, 'viewer');

    await tester.tap(_landingIcon());
    await tester.pumpAndSettle();

    expect(find.byType(LineUpMediaCarousel), findsOneWidget);
    expect(find.text('Edit'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(LineUpMediaCarousel),
        matching: find.byIcon(LucideIcons.trash2),
      ),
      findsNothing,
    );
  });

  testWidgets('a viewer opens a lineup origin, without its edit menu',
      (tester) async {
    await _pumpMap(tester, 'viewer');

    await tester.tap(_originAgent());
    await tester.pumpAndSettle();

    expect(find.byType(LineUpPanelDialog), findsOneWidget);

    // A lineup row offers no menu of edits.
    await tester.tapAt(
      tester.getCenter(
        find.byKey(const ValueKey('lineup-panel-row-breach-item')),
      ),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.text('Delete lineup'), findsNothing);
  });

  testWidgets('a viewer cannot move, delete or target what is placed',
      (tester) async {
    final container = await _pumpMap(tester, 'viewer');
    final lineUpsBefore = container.read(lineUpProvider);
    final agentsBefore = container.read(agentProvider);

    await _hover(tester, _originAgent());
    expect(container.read(hoveredDeleteTargetProvider), isNull);

    await tester.drag(_originAgent(), const Offset(70, 45));
    await tester.drag(
      find.byKey(const ValueKey('entity-jett-agent')),
      const Offset(70, 45),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    await tester.tapAt(
      tester.getCenter(_originAgent()),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(find.text('Delete origin'), findsNothing);
    expect(container.read(lineUpProvider), same(lineUpsBefore));
    expect(container.read(agentProvider), same(agentsBefore));
  });

  testWidgets('an editor keeps the lineup edit controls', (tester) async {
    final container = await _pumpMap(tester, 'editor');

    await _hover(tester, _originAgent());
    expect(container.read(hoveredDeleteTargetProvider)?.id, 'breach-group');

    await tester.tap(_landingIcon());
    await tester.pumpAndSettle();
    expect(find.byType(LineUpMediaCarousel), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
  });

  group('lineup edits', () {
    for (final MapEntry(key: edit, value: run) in _lineUpEdits.entries) {
      for (final MapEntry(key: reader, value: capabilities)
          in _readers.entries) {
        final refused = !capabilities.canEditPages;
        test(
            '${refused ? 'a' : 'an'} $reader '
            '${refused ? 'cannot' : 'can'} $edit', () {
          final container = _loadedLineUps(capabilities);
          addTearDown(container.dispose);
          final before = _lineUpContent(container);

          run(container.read(lineUpProvider.notifier));

          final after = _lineUpContent(container);
          if (refused) {
            expect(after, before);
            expect(container.read(lineUpProvider).edit, isNull,
                reason: 'Edit placement ends with nothing written');
          } else {
            expect(after, isNot(before));
          }
        });
      }
    }

    test("the server's lineups still reach a viewer", () {
      final container =
          _loadedLineUps(StrategyCapabilities.fromCloudRole('viewer'));
      addTearDown(container.dispose);

      container.read(lineUpProvider.notifier).mergeRemote(LineUpGraph.empty);
      expect(container.read(lineUpProvider).links, isEmpty);

      container
          .read(lineUpProvider.notifier)
          .addRecovered(LineUpGraph.fromLegacyGroups([_breachGroup()]));
      expect(container.read(lineUpProvider).links, hasLength(1));
    });
  });

  testWidgets(
      'Edit media saved after the reader became a viewer closes without '
      'saving', (tester) async {
    final container =
        _loadedLineUps(StrategyCapabilities.fromCloudRole('editor'));
    addTearDown(container.dispose);
    final before = _lineUpContent(container);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: ToastificationWrapper(
        child: ShadApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ShadButton(
                onPressed: () => showShadDialog<void>(
                  context: context,
                  builder: (_) =>
                      const CreateLineupDialog(linkId: 'breach-item'),
                ),
                child: const Text('Edit lineup'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Edit lineup'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, 'Retake');

    container.read(_capabilities.notifier).state =
        StrategyCapabilities.fromCloudRole('viewer');
    await tester.tap(find.text('Done'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      _toast('You can no longer edit this strategy, so this lineup was not '
          'saved.'),
      findsOneWidget,
    );
    toastification.dismissAll(delayForAnimation: false);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.byType(CreateLineupDialog), findsNothing);
    expect(_lineUpContent(container), before);
  });
}

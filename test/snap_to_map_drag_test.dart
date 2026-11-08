import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/map_lines.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/canvas_selection_provider.dart';
import 'package:icarus/providers/map_lines_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/snap_to_map_key_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/canvas_selection_layer.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/placed_widget_builder.dart';
import 'package:icarus/widgets/global_shortcuts.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _AscentAttack extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: true);
}

class _AscentDefense extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: false);
}

class _OpenStrategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        strategyId: 'snap-to-map',
        strategyName: null,
        source: StrategySource.local,
        storageDirectory: null,
        isOpen: true,
      );

  @override
  void setUnsaved() {}
}

const _canvas = Size(1600, 900);
const _agentAt = Offset(800, 500);

/// The agent's dot where it starts, in world units.
final _dot = _agentAt + CoordinateSystem.virtualToWorld(storedAgentAnchor);

/// A wall to the left of the agent, from the agent's height down, meeting a
/// floor edge below it: an inside corner.
final _wallX = _dot.dx - 60;
final _floorY = _dot.dy + 120;
final _lines = MapLines([
  (Offset(_wallX, _dot.dy - 200), Offset(_wallX, _floorY)),
  (Offset(_wallX, _floorY), Offset(_wallX + 300, _floorY)),
]);

/// World units per canvas pixel on [_canvas].
double get _perPixel => CoordinateSystem.instance
    .screenToCoordinate(
      const Offset(1, 0),
    )
    .dx;

Future<ProviderContainer> _pumpCanvas(
  WidgetTester tester, {
  bool defense = false,
  void Function(ProviderContainer container)? fill,
}) async {
  tester.view
    ..physicalSize = _canvas
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  CoordinateSystem(playAreaSize: _canvas);
  final container = ProviderContainer(overrides: [
    mapProvider.overrideWith(defense ? _AscentDefense.new : _AscentAttack.new),
    strategyProvider.overrideWith(_OpenStrategy.new),
    mapLinesProvider.overrideWith((ref, map) => _lines),
  ]);
  addTearDown(container.dispose);
  if (fill != null) {
    fill(container);
  } else {
    container.read(agentProvider.notifier).fromHive([
      PlacedAgent(
        id: 'jett',
        type: AgentType.jett,
        position: _agentAt,
        isAlly: true,
      ),
    ]);
  }
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: ShadApp(
      themeMode: ThemeMode.dark,
      darkTheme: ShadThemeData(
        brightness: Brightness.dark,
        colorScheme: Settings.tacticalVioletTheme,
      ),
      home: GlobalShortcuts(
        child: Scaffold(
          body: SizedBox(
            width: _canvas.width,
            height: _canvas.height,
            child: const CanvasSelectionLayer(
              enabled: true,
              child: PlacedWidgetBuilder(),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return container;
}

/// Presses the mouse on [at] and moves it past the slop that starts a drag.
Future<TestGesture> _startDrag(WidgetTester tester, Offset at) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: at);
  await tester.pump();
  await mouse.down(at);
  await tester.pump();
  await mouse.moveBy(const Offset(30, 0));
  await tester.pump();
  return mouse;
}

Future<void> _drop(WidgetTester tester, TestGesture mouse) async {
  await mouse.up();
  await tester.pumpAndSettle();
  await mouse.removePointer();
}

/// Drags the item drawn at [from] so the pointer ends [by] canvas pixels
/// away, with Alt held throughout unless [alt] is false.
Future<void> _dragBy(
  WidgetTester tester,
  Offset from,
  Offset by, {
  bool alt = true,
}) async {
  if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  final mouse = await _startDrag(tester, from);
  await mouse.moveTo(from + by);
  await tester.pump();
  await _drop(tester, mouse);
  if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await tester.pump();
}

Offset _agentCentre(WidgetTester tester) =>
    tester.getCenter(find.byType(AgentWidget).first);

Offset _savedDot(ProviderContainer container, [String id = 'jett']) =>
    container
        .read(agentProvider)
        .firstWhere((agent) => agent.id == id)
        .position +
    CoordinateSystem.virtualToWorld(storedAgentAnchor);

void main() {
  test('reads the lines the map draws, where the canvas draws them', () {
    const svg = '''
<svg width="100" height="50" viewBox="0 0 100 50" fill="none" xmlns="http://www.w3.org/2000/svg">
<mask id="m"><path d="M0 0H100" stroke="#B27C40"/></mask>
<path d="M10 10H90V40H10Z" fill="#271406"/>
<path d="M9.5 9.5H90.5V40.5H9.5Z" fill="#B27C40"/>
<path d="M50 10V40" stroke="#B27C40" stroke-width="0.5"/>
<path d="M60 10V40" stroke="#B27C40" stroke-opacity="0.23"/>
<circle cx="30" cy="25" r="5" stroke="#b27c40"/>
</svg>''';
    final lines = MapLines.fromSvg(svg);
    // Fitted to the map's area, 1240 by 1000, centred in the world.
    const scale = 1240 / 100;
    const left = (1000 * 16 / 9 - 1240) / 2;
    const top = (1000 - 50 * scale) / 2;
    Offset world(double x, double y) =>
        Offset(left + x * scale, top + y * scale);

    // The floor's edge, the full-strength stroke and the circle: 4 + 1 + 24.
    expect(lines.segments, hasLength(29));
    expect(lines.nearest(world(10, 25), 0.01), isNotNull);
    expect(lines.nearest(world(50, 25), 0.01), isNotNull);
    expect(lines.nearest(world(35, 25), 0.01), isNotNull);
    // The faint stroke, the outline fill's sides and the mask are left out.
    expect(lines.nearest(world(60, 25), 1), isNull);
    expect(lines.nearest(world(9.5, 25), 0.5 * scale - 0.01), isNull);
    expect(lines.nearest(world(50, 0), 1), isNull);
  });

  test('Ascent\'s floor corner lands on the drawn corner', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final source = await rootBundle.loadString('assets/maps/ascent_map.svg');
    final lines = MapLines.fromSvg(source);
    // The floor path starts at (0.5, 151) in a 411 by 474 drawing, which
    // fits the map's height.
    const scale = 1000 / 474;
    const left = (1000 * 16 / 9 - 1240) / 2 + (1240 - 411 * scale) / 2;
    final corner = Offset(left + 0.5 * scale, 151 * scale);
    expect(lines.nearest(corner, 0.001), isNotNull);
    expect(lines.segments.length, greaterThan(200));
  });

  testWidgets('near a line, Alt puts the dot on it', (tester) async {
    final container = await _pumpCanvas(tester);

    // 40 px left takes the dot within reach of the wall, 60 world units away.
    await _dragBy(tester, _agentCentre(tester), const Offset(-40, 0));

    final dot = _savedDot(container);
    expect(dot.dx, closeTo(_wallX, 0.01));
    expect(dot.dy, closeTo(_dot.dy, 0.5));
  });

  testWidgets('away from every line the item goes where the pointer does', (
    tester,
  ) async {
    final container = await _pumpCanvas(tester);

    await _dragBy(tester, _agentCentre(tester), const Offset(-10, -100));

    final dot = _savedDot(container);
    expect(dot.dx, closeTo(_dot.dx - 10 * _perPixel, 0.5));
    expect(dot.dy, closeTo(_dot.dy - 100 * _perPixel, 0.5));
  });

  testWidgets('without Alt the same drag does not snap', (tester) async {
    final container = await _pumpCanvas(tester);

    await _dragBy(
      tester,
      _agentCentre(tester),
      const Offset(-40, 0),
      alt: false,
    );

    expect(_savedDot(container).dx, closeTo(_dot.dx - 40 * _perPixel, 0.5));
  });

  testWidgets('the dot slides along the line after the pointer', (
    tester,
  ) async {
    await _pumpCanvas(tester);
    final from = _agentCentre(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    final mouse = await _startDrag(tester, from);
    final wall = CoordinateSystem.instance.coordinateToScreen(
      Offset(_wallX, 0),
    );
    for (final down in const [0.0, 30.0, 60.0]) {
      await mouse.moveTo(from + Offset(-45, down));
      await tester.pump();
      final preview = tester.getCenter(find.byType(AgentWidget).last);
      expect(preview.dx, closeTo(wall.dx, 0.5));
      expect(preview.dy, closeTo(from.dy + down, 0.5));
    }
    await _drop(tester, mouse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  });

  testWidgets('pushed past an inside corner, the dot sits in it', (
    tester,
  ) async {
    final container = await _pumpCanvas(tester);

    // Past both the wall and the floor's edge, by a little.
    final corner = CoordinateSystem.instance.coordinateToScreen(
      Offset(_wallX, _floorY),
    );
    final from = _agentCentre(tester);
    await _dragBy(tester, from, corner + const Offset(-8, 8) - from);

    final dot = _savedDot(container);
    expect(dot.dx, closeTo(_wallX, 0.01));
    expect(dot.dy, closeTo(_floorY, 0.01));
  });

  testWidgets('Alt moves the item with the pointer still', (tester) async {
    final container = await _pumpCanvas(tester);
    final from = _agentCentre(tester);
    final wall = CoordinateSystem.instance.coordinateToScreen(
      Offset(_wallX, 0),
    );

    final mouse = await _startDrag(tester, from);
    await mouse.moveTo(from + const Offset(-40, 0));
    await tester.pump();
    final preview = find.byType(AgentWidget).last;
    expect(tester.getCenter(preview).dx, closeTo(from.dx - 40, 0.5));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(tester.getCenter(preview).dx, closeTo(wall.dx, 0.5));

    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(tester.getCenter(preview).dx, closeTo(from.dx - 40, 0.5));

    await _drop(tester, mouse);
    expect(_savedDot(container).dx, closeTo(_dot.dx - 40 * _perPixel, 0.5));
  });

  testWidgets('on the defense side the line is where the map draws it', (
    tester,
  ) async {
    final container = await _pumpCanvas(tester, defense: true);

    // The map is turned half a turn, so the wall is drawn to the right.
    await _dragBy(tester, _agentCentre(tester), const Offset(40, 0));

    final dot = _savedDot(container);
    expect(dot.dx, closeTo(_wallX, 0.01));
    expect(dot.dy, closeTo(_dot.dy, 0.5));
  });

  testWidgets('an ability snaps by the dot its drop goes by', (tester) async {
    // Phoenix's Blaze is a wall drawn from its dot at one end.
    final blaze = AgentData.agents[AgentType.pheonix]!.abilities.first;
    final mapScale = Maps.mapScale[MapValue.ascent]!;
    final anchor = CoordinateSystem.virtualToWorld(
      storedAbilityAnchor(ability: blaze.abilityData!, mapScale: mapScale),
    );
    final container = await _pumpCanvas(
      tester,
      fill: (container) => container.read(abilityProvider.notifier).fromHive([
        PlacedAbility(id: 'blaze', data: blaze, position: _dot - anchor),
      ]),
    );
    Offset savedDot() =>
        container.read(abilityProvider).single.position + anchor;
    expect(savedDot(), _dot);

    final at = CoordinateSystem.instance.coordinateToScreen(_dot);
    await _dragBy(tester, at, const Offset(-40, 0));

    expect(savedDot().dx, closeTo(_wallX, 0.01));
    expect(savedDot().dy, closeTo(_dot.dy, 0.5));
  });

  testWidgets('a selection moves together, the item pressed on the line', (
    tester,
  ) async {
    final container = await _pumpCanvas(
      tester,
      fill: (container) => container.read(agentProvider.notifier).fromHive([
        PlacedAgent(
          id: 'jett',
          type: AgentType.jett,
          position: _agentAt,
          isAlly: true,
        ),
        PlacedAgent(
          id: 'sova',
          type: AgentType.sova,
          position: _agentAt + const Offset(150, 0),
          isAlly: true,
        ),
      ]),
    );
    container.read(canvasSelectionProvider.notifier).select([
      (kind: SelectableKind.agent, id: 'jett'),
      (kind: SelectableKind.agent, id: 'sova'),
    ]);
    await tester.pump();

    final jett = tester.getCenter(find.byType(AgentWidget).first);
    await _dragBy(tester, jett, const Offset(-40, 0));

    expect(_savedDot(container).dx, closeTo(_wallX, 0.5));
    expect(
      _savedDot(container, 'sova').dx,
      closeTo(_savedDot(container).dx + 150, 0.01),
    );
  });

  testWidgets('leaving the window lets go of Alt', (tester) async {
    final container = await _pumpCanvas(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    expect(container.read(snapToMapKeyProvider), isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(container.read(snapToMapKeyProvider), isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  });
}

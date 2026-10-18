import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/replay/replay_cone_cuts.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_drawing.dart';
import 'package:icarus/replay/replay_frame.dart';
import 'package:icarus/replay/replay_map_projection.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:icarus/replay_view.dart';
import 'package:icarus/widgets/replay/replay_canvas.dart';
import 'package:icarus/widgets/inset_shadow_decoration.dart';
import 'package:icarus/widgets/keybind_badge.dart';
import 'package:icarus/widgets/replay/replay_roster.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'replay_test_support.dart';

const jett = 'add6443a-41bd-e414-f6ad-e58d267f4e95';
const omen = '8e253930-4c05-31dd-1b6c-968525494517';

const reds = ['r0', 'r1', 'r2', 'r3', 'r4'];
const blues = ['b0', 'b1', 'b2', 'b3', 'b4'];

/// Ten players, five Jetts on Red (attacking both rounds) and five Omens
/// on Blue, each standing still at their own spot, one sample a second.
/// [walker] walks along x instead, 1 cm a millisecond.
ReplayDocument tenPlayers({
  List<Map<String, Object?>> kills = const [],
  String? walker,
}) {
  final records = <List<num>>[];
  final movement = <String, Object?>{};
  void stream(String subject, List<List<num>> samples) {
    movement[subject] = {
      'offset': records.length * 24,
      'count': samples.length
    };
    records.addAll(samples);
  }

  for (final (team, subjects) in [(0, reds), (1, blues)]) {
    for (var i = 0; i < subjects.length; i++) {
      final subject = subjects[i];
      final x = -1200.0 + i * 600;
      final y = team * 1200.0;
      stream(subject, [
        for (var t = 0; t <= 120000; t += 1000)
          [t, subject == walker ? x + t / 10 : x, y, 100, 90, 0],
      ]);
    }
  }
  return ReplayDocument.fromBytes(icrp(
    {
      ...sampleJson(),
      'players': [
        for (final subject in reds)
          {'subject': subject, 'agentId': jett, 'team': 'Red'},
        for (final subject in blues)
          {'subject': subject, 'agentId': omen, 'team': 'Blue'},
      ],
      'rounds': [
        {'index': 0, 'startMs': 0, 'endMs': 60000, 'attackingTeam': 'Red'},
        {'index': 1, 'startMs': 60000, 'endMs': 120000, 'attackingTeam': 'Red'},
      ],
      'kills': kills,
      'vitals': <String, Object?>{},
      'movement': movement,
    },
    records: records,
  ));
}

/// Records which players' cones a frame asks to be cut, cutting none.
class _RecordingCuts implements ReplayConeCuts {
  final wanted = <String>[];

  @override
  void want(String subject, ReplayConeAim aim) => wanted.add(subject);

  @override
  ReplayConeCut? latest(String subject) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Preferences extends AppPreferencesNotifier {
  @override
  AppPreferences build() => AppPreferences(
        defaultThemeProfileIdForNewStrategies:
            MapThemeProfilesProvider.immutableDefaultProfileId,
      );
}

class _Profiles extends MapThemeProfilesProvider {
  @override
  MapThemeProfilesState build() => MapThemeProfilesState(
        profiles: [MapThemeProfilesProvider.immutableDefaultProfile],
        defaultProfileIdForNewStrategies:
            MapThemeProfilesProvider.immutableDefaultProfileId,
      );
}

void main() {
  final projection = ReplayMapProjection.forMapPath(
    '/Game/Maps/Juliett/Juliett',
  )!;

  ReplayPlayback playback(ReplayDocument document) => ReplayPlayback(
        document: document,
        projection: projection,
        perspective: ReplayTeam.red,
      );

  List<String> coneIds(ReplayFrame frame) => [
        for (final agent in frame.agents)
          if (agent is PlacedViewConeAgent) agent.id,
      ];

  group('frame', () {
    final frames = ReplayFrameBuilder(tenPlayers(), projection);

    test('everyone is on the map with a cone while no one is watched', () {
      final frame = frames.frameAt(1000, perspective: ReplayTeam.red);
      expect(coneIds(frame), hasLength(10));
    });

    test('watching one player draws only their cone', () {
      final frame =
          frames.frameAt(1000, perspective: ReplayTeam.red, watching: 'r2');
      expect(frame.agents, hasLength(10));
      expect(coneIds(frame), [ReplayFrameBuilder.agentIdOf('r2')]);
      for (final agent in frame.agents) {
        if (agent is PlacedViewConeAgent) continue;
        expect((agent as PlacedAgent).state, AgentState.none);
      }
    });

    test('no one else has a cone cut', () {
      final cuts = _RecordingCuts();
      final frame = frames.frameAt(
        1000,
        perspective: ReplayTeam.red,
        cuts: cuts,
        watching: 'b3',
      );
      expect(cuts.wanted, ['b3']);
      expect(frame.cones.keys, [ReplayFrameBuilder.agentIdOf('b3')]);

      final everyone = _RecordingCuts();
      frames.frameAt(1000, perspective: ReplayTeam.red, cuts: everyone);
      expect(everyone.wanted, [...reds, ...blues]);
    });

    test('a dead watched player has no cone, and their next round does', () {
      final frames = ReplayFrameBuilder(
        tenPlayers(kills: [
          {'timeMs': 5000, 'victim': 'r2', 'killer': 'b0'},
        ]),
        projection,
      );
      final dead =
          frames.frameAt(6000, perspective: ReplayTeam.red, watching: 'r2');
      expect(coneIds(dead), isEmpty);
      final body = dead.agents.singleWhere(
          (agent) => agent.id == ReplayFrameBuilder.agentIdOf('r2'));
      expect((body as PlacedAgent).state, AgentState.dead);

      final respawned =
          frames.frameAt(61000, perspective: ReplayTeam.red, watching: 'r2');
      expect(coneIds(respawned), [ReplayFrameBuilder.agentIdOf('r2')]);
    });
  });

  group('playback', () {
    test('watching redraws the moment; swapping perspective keeps it', () {
      final p = playback(tenPlayers())..seek(1000);
      expect(coneIds(p.frame), hasLength(10));
      p.watch('r2');
      expect(coneIds(p.frame), [ReplayFrameBuilder.agentIdOf('r2')]);
      p.perspective = ReplayTeam.blue;
      expect(p.watching, 'r2');
      expect(coneIds(p.frame), [ReplayFrameBuilder.agentIdOf('r2')]);
      expect(p.frame.agents.firstWhere((a) => a.id.endsWith('r2')).isAlly,
          isFalse);
      p.stopWatching();
      expect(coneIds(p.frame), hasLength(10));
    });

    test('picking the watched player follows them again, then stops', () {
      final p = playback(tenPlayers());
      p.watch('r2');
      expect((p.watching, p.following), ('r2', true));
      p.stopFollowing();
      expect((p.watching, p.following), ('r2', false));
      p.watch('r2');
      expect((p.watching, p.following), ('r2', true));
      p.watch('r2');
      expect((p.watching, p.following), (null, false));
      p.watch('r2');
      p.watch('b1');
      expect((p.watching, p.following), ('b1', true));
    });
  });

  group('keys', () {
    Future<ReplayPlayback> keyboard(WidgetTester tester) async {
      final p = playback(tenPlayers());
      addTearDown(p.dispose);
      await tester.pumpWidget(Focus(
        autofocus: true,
        onKeyEvent: (_, event) => replayKey(p, event),
        child: const SizedBox(),
      ));
      await tester.pump();
      return p;
    }

    testWidgets('1–5 watch the allies, 6–0 the enemies, as listed',
        (tester) async {
      final p = await keyboard(tester);
      final expected = {
        LogicalKeyboardKey.digit1: 'r0',
        LogicalKeyboardKey.digit3: 'r2',
        LogicalKeyboardKey.digit5: 'r4',
        LogicalKeyboardKey.digit6: 'b0',
        LogicalKeyboardKey.digit9: 'b3',
        LogicalKeyboardKey.digit0: 'b4',
      };
      for (final MapEntry(:key, :value) in expected.entries) {
        await tester.sendKeyEvent(key);
        expect(p.watching, value, reason: '$key');
      }
      // Again: stops watching.
      await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
      expect(p.watching, isNull);
    });

    testWidgets('Esc stops watching', (tester) async {
      final p = await keyboard(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      expect(p.watching, 'r1');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(p.watching, isNull);
      // With no one watched, Esc is left for whatever else wants it.
      expect(
        replayKey(
          p,
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.escape,
            logicalKey: LogicalKeyboardKey.escape,
            timeStamp: Duration.zero,
          ),
        ),
        KeyEventResult.ignored,
      );
    });

    testWidgets('the keys follow a perspective swap', (tester) async {
      final p = await keyboard(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      expect(p.watching, 'r1');
      p.perspective = ReplayTeam.blue;
      // Still watching the same player; the keys now count from Blue.
      expect(p.watching, 'r1');
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      expect(p.watching, 'b0');
      await tester.sendKeyEvent(LogicalKeyboardKey.digit7);
      expect(p.watching, 'r1');
      expect(p.watchKeyOf(p.document.playerBySubject('r1')!), '7');
      expect(p.watchKeyOf(p.document.playerBySubject('b4')!), '5');
    });
  });

  group('roster', () {
    Future<ReplayPlayback> roster(
      WidgetTester tester, {
      List<Map<String, Object?>> kills = const [],
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(600, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final p = playback(tenPlayers(kills: kills))..seek(1000);
      addTearDown(p.dispose);
      await tester.pumpWidget(ProviderScope(
        child: ShadApp(
          home: Scaffold(
            body: Focus(
              autofocus: true,
              onKeyEvent: (_, event) => replayKey(p, event),
              child: Align(
                alignment: Alignment.topRight,
                child: SizedBox(height: 880, child: ReplayRoster(playback: p)),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      return p;
    }

    /// The key drawn on [subject]'s row.
    KeybindBadge keyOf(WidgetTester tester, String subject) =>
        tester.widget<KeybindBadge>(find.descendant(
          of: find.byKey(ValueKey(subject)),
          matching: find.byType(KeybindBadge),
        ));

    /// The tooltip shown while the mouse rests on [row].
    Future<String> tooltipOf(WidgetTester tester, Finder row) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(row));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final shown = find
          .textContaining(RegExp(r'^(Watch|Stop watching|Follow) '))
          .evaluate()
          .map((element) => (element.widget as Text).data!)
          .toList();
      await mouse.moveTo(Offset.zero);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await mouse.removePointer();
      return shown.single;
    }

    testWidgets("a swap never hands one player's row to another",
        (tester) async {
      final p = await roster(tester);
      final subjects = [...reds, ...blues];
      Map<String, State> rows() => {
            for (final subject in subjects)
              subject: tester.state(find.byKey(ValueKey(subject))),
          };
      p.watch('r2');
      await tester.pump();
      final before = rows();
      p.perspective = p.perspective.other;
      await tester.pump();
      final after = rows();
      for (final subject in subjects) {
        // Either the player's own row, or a new one: never another's.
        final kept = identical(after[subject], before[subject]);
        expect(kept || !before.values.contains(after[subject]), isTrue,
            reason: subject);
      }
      p.stopWatching();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('clicking a row watches that player, and again stops',
        (tester) async {
      final p = await roster(tester);
      await tester.tap(find.text('Jett').at(2));
      await tester.pump();
      expect((p.watching, p.following), ('r2', true));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('Omen').at(4));
      await tester.pump();
      expect(p.watching, 'b4');
      await tester.tap(find.text('Omen').at(4));
      await tester.pump();
      expect(p.watching, isNull);
    });

    testWidgets('the watched row is raised and ringed in violet',
        (tester) async {
      final p = await roster(tester);
      List<AnimatedContainer> rows() => tester
          .widgetList<AnimatedContainer>(find.descendant(
            of: find.byWidgetPredicate(
                (widget) => widget.runtimeType.toString() == '_PlayerRow'),
            matching: find.byType(AnimatedContainer),
          ))
          .toList();
      expect(rows(), hasLength(10));
      expect(rows().where((row) => row.foregroundDecoration != null), isEmpty);
      p.watch('r3');
      await tester.pump();
      final watched = rows()[3];
      expect(watched.decoration, isA<InsetShadowDecoration>());
      expect(
        (watched.foregroundDecoration! as BoxDecoration).border,
        Border.all(color: Settings.accentInk),
      );
      expect(rows().where((row) => row.foregroundDecoration != null),
          hasLength(1));
    });

    testWidgets('each row shows its key, and the key watches that player',
        (tester) async {
      // r2 is dead: they keep their key, and can still be watched.
      final p = await roster(tester, kills: [
        {'timeMs': 500, 'victim': 'r2', 'killer': 'b0'},
      ]);
      final shown = {
        for (final subject in [...reds, ...blues])
          subject: keyOf(tester, subject).label,
      };
      expect(shown, {
        'r0': '1',
        'r1': '2',
        'r2': '3',
        'r3': '4',
        'r4': '5',
        'b0': '6',
        'b1': '7',
        'b2': '8',
        'b3': '9',
        'b4': '0',
      });
      for (final MapEntry(key: subject, value: label) in shown.entries) {
        await tester.sendKeyEvent(LogicalKeyboardKey(label.codeUnitAt(0)));
        await tester.pump();
        expect(p.watching, subject, reason: 'pressed $label');
        expect(keyOf(tester, subject).lit, isTrue, reason: subject);
        expect(
          [...reds, ...blues].where((other) => keyOf(tester, other).lit),
          [subject],
        );
      }
      // Seen from the other team, the keys count from them.
      p.perspective = p.perspective.other;
      await tester.pump();
      expect(
        [
          for (final subject in [...blues, ...reds])
            keyOf(tester, subject).label
        ],
        ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
      );
    });

    testWidgets('each row says how to watch its player', (tester) async {
      final p = await roster(tester);
      expect(
          await tooltipOf(tester, find.text('Jett').first), 'Watch Jett (1)');
      expect(
          await tooltipOf(tester, find.text('Omen').at(1)), 'Watch Omen (7)');
      p.watch('r0');
      await tester.pump();
      expect(await tooltipOf(tester, find.text('Jett').first),
          'Stop watching Jett (1)');
      p.stopFollowing();
      await tester.pump();
      expect(
          await tooltipOf(tester, find.text('Jett').first), 'Follow Jett (1)');
    });
  });

  group('map', () {
    setUp(() => CoordinateSystem(playAreaSize: const Size(1600, 900)));

    test('a click picks the agent whose icon it lands on', () {
      final frame = ReplayFrameBuilder(tenPlayers(), projection)
          .frameAt(1000, perspective: ReplayTeam.red);
      final coordinates = CoordinateSystem.instance;
      final anchor = CoordinateSystem.virtualToWorld(storedAgentAnchor);
      final r2 = frame.agents.singleWhere(
          (agent) => agent.id == ReplayFrameBuilder.agentIdOf('r2'));
      final centre = coordinates.coordinateToScreen(r2.position + anchor);
      final radius = coordinates.scale(Settings.agentSize) / 2;
      PlacedAgentNode? at(Offset point, {bool isAttack = true}) =>
          replayAgentAt(frame.agents, point,
              isAttack: isAttack, agentSize: Settings.agentSize);

      expect(at(centre)?.id, r2.id);
      expect(at(centre + Offset(radius, 0))?.id, r2.id);
      expect(at(centre + Offset(radius * 2, 0)), isNull);
      // On defense the map is turned round, and the agents with it.
      final turned = Offset(1600 - centre.dx, 900 - centre.dy);
      expect(at(turned, isAttack: false)?.id, r2.id);
      expect(at(centre, isAttack: false)?.id, isNot(r2.id));
    });

    test('the camera puts its focus in the middle of the viewport', () {
      const viewport = Size(1000, 900);
      final camera = replayCameraOn(const Offset(300, 200), 2, viewport);
      expect(MatrixUtils.transformPoint(camera, const Offset(300, 200)),
          const Offset(500, 450));
      expect(camera.getMaxScaleOnAxis(), 2);
    });

    test('the camera stops at the map edges, and centres a narrow map', () {
      const world = Size(1600, 900);
      Offset held(Matrix4 camera, Size viewport) {
        final at =
            replayCameraClamped(camera, world, viewport).getTranslation();
        return Offset(at.x, at.y);
      }

      // Wider and as tall as the view: it slides sideways, edge to edge,
      // and not at all up or down.
      const narrow = Size(1300, 900);
      expect(held(Matrix4.translationValues(500, 300, 0), narrow), Offset.zero);
      expect(held(Matrix4.translationValues(-900, -300, 0), narrow),
          const Offset(-300, 0));
      expect(held(Matrix4.translationValues(-120, 0, 0), narrow),
          const Offset(-120, 0));
      // Zoomed in, its far corner stops at the view's far corner.
      expect(
          held(
              Matrix4.diagonal3Values(3, 3, 1)
                ..setTranslationRaw(-1e5, -1e5, 0),
              narrow),
          const Offset(1300 - 4800, 900 - 2700));
      // Narrower than the view: it stays in the middle.
      expect(held(Matrix4.translationValues(-700, 0, 0), const Size(2000, 900)),
          const Offset(200, 0));
    });
  });

  group('canvas', () {
    const reservedRight = 296.0;

    Future<(ReplayPlayback, TransformationController)> canvas(
      WidgetTester tester, {
      String walker = 'r2',
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1600, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final p = playback(tenPlayers(walker: walker))..seek(1000);
      addTearDown(p.dispose);
      final drawing = ReplayDrawing(p);
      addTearDown(drawing.dispose);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          appPreferencesProvider.overrideWith(_Preferences.new),
          mapThemeProfilesProvider.overrideWith(_Profiles.new),
        ],
        child: ShadApp(
          home: Scaffold(
            body: ReplayCanvas(
              playback: p,
              drawing: drawing,
              map: projection.map,
              reservedRight: reservedRight,
            ),
          ),
        ),
      ));
      await tester.pump();
      final controller = tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!;
      return (p, controller);
    }

    /// Where [subject]'s icon is on screen now.
    Offset onScreen(
      ReplayPlayback p,
      TransformationController controller,
      String subject,
    ) {
      final agent = p.frame.agents.singleWhere(
          (agent) => agent.id == ReplayFrameBuilder.agentIdOf(subject));
      final anchor = CoordinateSystem.virtualToWorld(storedAgentAnchor);
      final scene =
          CoordinateSystem.instance.coordinateToScreen(agent.position + anchor);
      return MatrixUtils.transformPoint(controller.value, scene);
    }

    const middle = Offset((1600 - reservedRight) / 2, 450);

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    void expectCentred(Offset point) {
      expect(point.dx, closeTo(middle.dx, 0.5));
      expect(point.dy, closeTo(middle.dy, 0.5));
    }

    testWidgets('clicking an agent watches and follows them', (tester) async {
      final (p, controller) = await canvas(tester);
      await tester.tapAt(onScreen(p, controller, 'r2'));
      await tester.pump();
      expect((p.watching, p.following), ('r2', true));
      await settle(tester);
      expect(controller.value.getMaxScaleOnAxis(), closeTo(2, 1e-9));
      expectCentred(onScreen(p, controller, 'r2'));

      // They walk on; the camera keeps them centred.
      p.seek(4000);
      await tester.pump();
      expectCentred(onScreen(p, controller, 'r2'));

      // The rest are drawn without cones, dimmed.
      final faded = tester
          .widgetList<Opacity>(find.byType(Opacity))
          .where((opacity) => opacity.opacity < 1 && opacity.opacity > 0.5);
      expect(faded, hasLength(9));
    });

    testWidgets('a click on empty map keeps the watch', (tester) async {
      final (p, controller) = await canvas(tester);
      p.watch('b1');
      await settle(tester);
      await tester.tapAt(const Offset(40, 40));
      await tester.pump();
      expect((p.watching, p.following), ('b1', true));
    });

    testWidgets('panning stops following; picking them again resumes',
        (tester) async {
      final (p, controller) = await canvas(tester);
      p.watch('r2');
      await settle(tester);
      await tester.dragFrom(const Offset(300, 300), const Offset(150, 60));
      await settle(tester);
      expect((p.watching, p.following), ('r2', false));
      expect(
          (onScreen(p, controller, 'r2') - middle).distance, greaterThan(100));
      // Let the fling run out.
      await tester.pump(const Duration(seconds: 3));
      final panned = controller.value.clone();
      p.seek(5000);
      await tester.pump();
      // Left where the user put the map.
      expect(controller.value, panned);

      await tester.tapAt(onScreen(p, controller, 'r2'));
      await settle(tester);
      expect((p.watching, p.following), ('r2', true));
      expectCentred(onScreen(p, controller, 'r2'));
    });

    testWidgets('a fling still coasting does not carry the camera off them',
        (tester) async {
      final (p, controller) = await canvas(tester);
      // Zoomed in, so the fling has room to coast.
      controller.value = Matrix4.diagonal3Values(3, 3, 1)
        ..setTranslationRaw(-1600, -900, 0);
      await tester.fling(find.byType(InteractiveViewer),
          const Offset(-300, -200), 3000);
      await tester.pump(const Duration(milliseconds: 16));
      p.watch('r2');
      await settle(tester);
      // Well past where the fling would have run out.
      await tester.pump(const Duration(seconds: 3));
      expect((p.watching, p.following), ('r2', true));
      expectCentred(onScreen(p, controller, 'r2'));
    });

    testWidgets('the watched agent is drawn above the rest', (tester) async {
      final (p, _) = await canvas(tester);
      List<String> drawn() => [
            for (final element in find
                .byWidgetPredicate((widget) =>
                    widget.key is ValueKey<String> &&
                    (widget.key! as ValueKey<String>)
                        .value
                        .startsWith('replay-player-'))
                .evaluate())
              (element.widget.key! as ValueKey<String>).value,
          ];
      final first = drawn().first;
      p.watch(first.substring('replay-player-'.length));
      await tester.pump();
      expect(drawn().last, first);
    });

    testWidgets('zooming with the wheel keeps following', (tester) async {
      final (p, controller) = await canvas(tester);
      p.watch('r2');
      await settle(tester);
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(const Offset(200, 200)));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -200)));
      await tester.pump();
      expect(controller.value.getMaxScaleOnAxis(), greaterThan(2));
      expect(p.following, isTrue);
      expectCentred(onScreen(p, controller, 'r2'));
    });

    /// Where the top-left corner of the box the dot grid and map are drawn
    /// in is on screen now.
    Offset worldCorner(TransformationController controller) =>
        MatrixUtils.transformPoint(controller.value, Offset.zero);

    testWidgets('dragging the map past its edge stops at the edge',
        (tester) async {
      final (_, controller) = await canvas(tester);
      await tester.dragFrom(const Offset(300, 300), const Offset(900, 600));
      await tester.pump(const Duration(seconds: 3));
      expect(worldCorner(controller), Offset.zero);
      await tester.dragFrom(const Offset(900, 600), const Offset(-1200, -800));
      await tester.pump(const Duration(seconds: 3));
      expect(worldCorner(controller),
          const Offset(1600 - reservedRight - 1600, 0));

      // Moved by code, as far as it likes: held at the edge all the same.
      controller.value = Matrix4.diagonal3Values(3, 3, 1)
        ..setTranslationRaw(5000, 5000, 0);
      expect(worldCorner(controller), Offset.zero);
    });

    testWidgets('following a player at the map edge keeps both in view',
        (tester) async {
      // r4 walks north to the top edge of the map.
      final (p, controller) = await canvas(tester, walker: 'r4');
      p.seek(10000);
      p.watch('r4');
      await settle(tester);
      expectCentred(onScreen(p, controller, 'r4'));

      var lastTop = worldCorner(controller).dy;
      for (var t = 10000; t <= 56000; t += 500) {
        p.seek(t);
        await tester.pump();
        final top = worldCorner(controller).dy;
        // The map never comes down off the top of the view, and the camera
        // slides up to the edge rather than jumping to it.
        expect(top, lessThanOrEqualTo(0));
        expect((top - lastTop).abs(), lessThan(20));
        lastTop = top;
        final at = onScreen(p, controller, 'r4');
        expect(at.dx, closeTo(middle.dx, 0.5));
        expect(at.dy, inInclusiveRange(0, 900));
      }
      // At the edge they sit above the middle, the map's edge at the top.
      expect(lastTop, 0);
      expect(onScreen(p, controller, 'r4').dy, lessThan(middle.dy - 200));
      expect(p.following, isTrue);
    });
  });
}

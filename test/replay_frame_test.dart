import 'dart:typed_data';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/replay/replay_cone_cuts.dart';
import 'package:icarus/replay/replay_cone_worker.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_frame.dart';
import 'package:icarus/replay/replay_map_projection.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:icarus/view_cone/vision_occluders.dart';
import 'package:icarus/widgets/replay/replay_effects.dart';

import 'replay_test_support.dart';

const jett = 'add6443a-41bd-e414-f6ad-e58d267f4e95';
const omen = '8e253930-4c05-31dd-1b6c-968525494517';
const omenSmoke =
    '/Game/Characters/Wraith/S0/Ability_4/Zone_Wraith_4_Smoke.Zone_Wraith_4_Smoke_C';

/// One round 0–60 s, a second from 60 s; Red attacks both.
ReplayDocument document({
  List<Map<String, Object?>>? players,
  List<Map<String, Object?>> kills = const [],
  Map<String, Object?> vitals = const {},
  Map<String, Object?> blinds = const {},
  List<Map<String, Object?>> utility = const [],
  Map<String, List<List<num>>> movement = const {},
  Map<String, Object?> firstRound = const {},
}) {
  final records = <List<num>>[];
  final movementJson = <String, Object?>{};
  for (final entry in movement.entries) {
    movementJson[entry.key] = {
      'offset': records.length * 24,
      'count': entry.value.length,
    };
    records.addAll(entry.value);
  }
  return ReplayDocument.fromBytes(icrp(
    {
      ...sampleJson(),
      'players': players ??
          [
            {'subject': 'a', 'agentId': jett, 'team': 'Red'},
            {'subject': 'b', 'agentId': omen, 'team': 'Blue'},
          ],
      'rounds': [
        {
          'index': 0,
          'startMs': 0,
          'endMs': 60000,
          'attackingTeam': 'Red',
          ...firstRound,
        },
        {'index': 1, 'startMs': 60000, 'endMs': 120000, 'attackingTeam': 'Red'},
      ],
      'kills': kills,
      'vitals': vitals,
      'blinds': blinds,
      'utility': utility,
      'movement': movementJson,
    },
    records: records,
  ));
}

/// Standing still at (x, 0) from [from] to [to], one sample a second.
List<List<num>> still(int from, int to, {double x = 0}) => [
      for (var t = from; t <= to; t += 1000) [t, x, 0, 100, 90, 0],
    ];

void main() {
  final projection = ReplayMapProjection.forMapPath(
    '/Game/Maps/Juliett/Juliett',
  )!;

  ReplayFrameBuilder builder(ReplayDocument document) =>
      ReplayFrameBuilder(document, projection);

  ReplayPlayer player(ReplayDocument document, String subject) =>
      document.playerBySubject(subject)!;

  group('alive', () {
    test('a death after a health reading wins', () {
      final doc = document(
        kills: [
          {'timeMs': 20000, 'victim': 'a', 'killer': 'b'},
        ],
        vitals: {
          'a': [
            [0, 100, 0],
            [15000, 40, 0],
          ],
        },
      );
      final frames = builder(doc);
      final a = player(doc, 'a');
      expect(frames.isAlive(a, 19999, doc.roundAt(19999)), isTrue);
      expect(frames.isAlive(a, 25000, doc.roundAt(25000)), isFalse);
    });

    test('a revive after the death brings them back', () {
      final doc = document(
        kills: [
          {'timeMs': 20000, 'victim': 'a', 'killer': 'b'},
        ],
        vitals: {
          'a': [
            [0, 100, 0],
            [20000, 0, 0],
            [30000, 30, 0],
          ],
        },
      );
      final frames = builder(doc);
      final a = player(doc, 'a');
      expect(frames.isAlive(a, 25000, doc.roundAt(25000)), isFalse);
      expect(frames.isAlive(a, 31000, doc.roundAt(31000)), isTrue);
    });

    test('a new round revives everyone, even with no fresh reading', () {
      final doc = document(
        kills: [
          {'timeMs': 20000, 'victim': 'a', 'killer': 'b'},
        ],
        vitals: {
          'a': [
            [20000, 0, 0],
          ],
        },
      );
      final frames = builder(doc);
      expect(
          frames.isAlive(player(doc, 'a'), 61000, doc.roundAt(61000)), isTrue);
      // And last round's reading is not shown as this round's health.
      expect(frames.playerState(player(doc, 'a'), 61000).health, isNull);
    });
  });

  group('frames', () {
    test('a quiet stream keeps a living player where they stood', () {
      final doc = document(movement: {
        'a': [
          [1000, 500, 0, 100, 90, 0],
        ],
      });
      final frame = builder(doc).frameAt(30000, perspective: ReplayTeam.red);
      expect(frame.agents.single, isA<PlacedViewConeAgent>());
    });

    test('a dead player stays where they fell', () {
      final doc = document(
        kills: [
          {'timeMs': 5000, 'victim': 'a', 'killer': 'b'},
        ],
        movement: {
          // The stream keeps moving after the death (the spectator camera).
          'a': [...still(0, 5000, x: 100), ...still(6000, 9000, x: 3000)],
        },
      );
      final frames = builder(doc);
      final atDeath = frames.playerState(player(doc, 'a'), 5000).pose!;
      final later = frames.playerState(player(doc, 'a'), 9000);
      expect(later.alive, isFalse);
      expect(later.pose!.position.x, atDeath.position.x);
      final agent = frames
          .frameAt(9000, perspective: ReplayTeam.red)
          .agents
          .single as PlacedAgent;
      expect(agent.state, AgentState.dead);
    });

    test('players with no team or unknown agent are not drawn', () {
      final doc = document(
        players: [
          {'subject': 'a', 'agentId': jett},
          {'subject': 'b', 'agentId': 'not-an-agent', 'team': 'Blue'},
        ],
        movement: {'a': still(0, 2000), 'b': still(0, 2000)},
      );
      expect(
        builder(doc).frameAt(1000, perspective: ReplayTeam.red).agents,
        isEmpty,
      );
    });

    test('ally and side follow the perspective', () {
      final doc = document(movement: {'a': still(0, 2000)});
      final frames = builder(doc);
      final red = frames.frameAt(1000, perspective: ReplayTeam.red);
      final blue = frames.frameAt(1000, perspective: ReplayTeam.blue);
      expect(red.isAttack, isTrue);
      expect(blue.isAttack, isFalse);
      expect(red.agents.single.isAlly, isTrue);
      expect(blue.agents.single.isAlly, isFalse);
    });

    test('the spike is planted until it is defused', () {
      final doc = document(firstRound: {
        'plant': {
          'timeMs': 20000,
          'position': [0, 0, 100],
        },
        'defuse': {'timeMs': 40000},
      });
      final frames = builder(doc);
      int spikes(int t) =>
          frames.frameAt(t, perspective: ReplayTeam.red).utilities.length;
      expect(spikes(19999), 0);
      expect(spikes(30000), 1);
      expect(spikes(40000), 0);
      expect(spikes(50000), 0);
    });

    test('a player off the map (a Kill Contract duel) is not drawn', () {
      final doc = document(movement: {
        'a': [
          [0, 0, 0, 100, 0, 0],
          [500, 900000, 900000, 100, 0, 0],
        ],
      });
      final frames = builder(doc);
      expect(
          frames.frameAt(0, perspective: ReplayTeam.red).agents, hasLength(1));
      expect(frames.frameAt(500, perspective: ReplayTeam.red).agents, isEmpty);
      expect(frames.playerState(player(doc, 'a'), 500).alive, isTrue);
    });

    test('ownerless utility is drawn only when one player could own it', () {
      final smoke = {
        'id': 1,
        'classPath': omenSmoke,
        'spawnMs': 1000,
        'endMs': 9000,
        'position': [0, 0, 100],
      };
      final sole = document(utility: [smoke]);
      final ability = builder(sole)
          .frameAt(2000, perspective: ReplayTeam.red)
          .abilities
          .single;
      expect(ability.isAlly, isFalse); // Omen is Blue.

      final twoOmens = document(
        players: [
          {'subject': 'a', 'agentId': omen, 'team': 'Red'},
          {'subject': 'b', 'agentId': omen, 'team': 'Blue'},
        ],
        utility: [smoke],
      );
      expect(
        builder(twoOmens).frameAt(2000, perspective: ReplayTeam.red).abilities,
        isEmpty,
      );
    });
  });

  group('flashes', () {
    // Flashed at 10 s for 2 s; the clear arrives just after.
    final flashed = {
      'a': [
        [10000, 2.0],
        [12003, 0],
      ],
    };

    test('a flash blinds fully, then sight comes back over its end', () {
      final doc = document(blinds: flashed, movement: {'a': still(0, 20000)});
      final frames = builder(doc);
      ReplayFrame at(int timeMs) =>
          frames.frameAt(timeMs, perspective: ReplayTeam.red);

      // Blind: no cone, and the icon fully washed.
      final blind = at(10500);
      final agent = blind.agents.single as PlacedAgent;
      expect(agent.state, AgentState.none);
      final landed = blind.effects.whereType<ReplayFlashed>().single;
      expect(landed.blindness, 1.0);
      // 500 ms of the 2 s flash have passed: a quarter of the outline.
      expect(landed.progress, closeTo(0.25, 1e-6));

      // 400 ms left of the 800 ms fade: half the sight is back.
      final fading = at(11600);
      final cone = fading.agents.single as PlacedViewConeAgent;
      expect(cone.length, closeTo(ReplayFrameBuilder.coneLength / 2, 1e-6));
      final half = fading.effects.whereType<ReplayFlashed>().single;
      expect(half.blindness, closeTo(0.5, 1e-6));
      expect(half.progress, closeTo(0.8, 1e-6));

      final clear = at(12100);
      expect(
        (clear.agents.single as PlacedViewConeAgent).length,
        ReplayFrameBuilder.coneLength,
      );
      expect(clear.effects.whereType<ReplayFlashed>(), isEmpty);
    });

    test('a cone shorter than the editor allows is no cone', () {
      final doc = document(blinds: flashed, movement: {'a': still(0, 20000)});
      // 50 ms into the 800 ms fade: a sixteenth of the sight is back.
      final frame = builder(doc).frameAt(11250, perspective: ReplayTeam.red);
      expect(frame.agents.single, isNot(isA<PlacedViewConeAgent>()));
    });

    test('the dead are never washed', () {
      final doc = document(
        blinds: flashed,
        kills: [
          {'timeMs': 10200, 'victim': 'a', 'killer': 'b'},
        ],
        movement: {'a': still(0, 20000)},
      );
      final frame = builder(doc).frameAt(10500, perspective: ReplayTeam.red);
      expect((frame.agents.single as PlacedAgent).state, AgentState.dead);
      expect(frame.effects.whereType<ReplayFlashed>(), isEmpty);
    });

    test('a decode without flashes reads as never flashed', () {
      final json = sampleJson()..remove('blinds');
      final doc = ReplayDocument.fromBytes(icrp(json));
      expect(doc.blinds, isEmpty);
    });
  });

  group('utility', () {
    const omenOrb =
        '/Game/Characters/Wraith/S0/Ability_4/Projectile_Wraith_4_Smoke.Projectile_Wraith_4_Smoke_C';
    Map<String, Object?> smoke({int spawnMs = 1000, int? endMs = 9000}) => {
          'id': 1,
          'classPath': omenSmoke,
          'owner': 'b',
          'spawnMs': spawnMs,
          'endMs': endMs,
          'position': [0, 0, 100],
        };

    test('a smoke blocks sight while it is up, as wide as it is drawn', () {
      final frames = builder(document(utility: [smoke()]));
      final up = frames.frameAt(2000, perspective: ReplayTeam.red);
      expect(up.occluders.single, isA<CircleOccluder>());
      // Omen's smoke is drawn as an image that fills its square; a cone's
      // shadow must leave from the edge of that image, not from inside it.
      final drawn = up.abilities.single.data.abilityData!
          .getSize(mapScale: Maps.mapScale[projection.map]!, abilitySize: 0);
      expect((up.occluders.single as CircleOccluder).radius,
          closeTo(CoordinateSystem.virtualLengthInWorld(drawn.dx / 2), 1e-9));
      expect(
          frames.frameAt(9600, perspective: ReplayTeam.red).occluders, isEmpty);
    });

    test('a utility rings as it activates and fades out as it ends', () {
      final frames = builder(document(utility: [smoke()]));
      ReplayFrame at(int t) => frames.frameAt(t, perspective: ReplayTeam.red);
      expect(at(1100).effects.whereType<ReplayActivation>(), hasLength(1));
      expect(at(2000).effects, isEmpty);
      // Ended at 9000: drawn fading for half a second, then gone, and never
      // part of what a capture saves.
      final leaving = at(9200);
      expect(leaving.abilities, isEmpty);
      final exit = leaving.effects.whereType<ReplayExit>().single;
      expect(exit.progress, closeTo(0.4, 1e-9));
      expect(at(9600).effects, isEmpty);
    });

    test('a thrown smoke flies as its icon, not as the smoke', () {
      final frames = builder(document(utility: [
        {
          'id': 2,
          'classPath': omenOrb,
          'owner': 'b',
          'spawnMs': 1000,
          'endMs': 2000,
          'position': [0, 0, 100],
          'path': [
            [1500, 500, 0, 100],
            [2000, 1000, 0, 100],
          ],
        },
      ]));
      final frame = frames.frameAt(1250, perspective: ReplayTeam.red);
      expect(frame.abilities, isEmpty);
      final flight = frame.effects.whereType<ReplayFlight>().single;
      // Half way to its first path point: the path is followed smoothly.
      final start = projection.toWorld(0, 0);
      final first = projection.toWorld(500, 0);
      expect((flight.trail.last - Offset.lerp(start, first, 0.5)!).distance,
          lessThan(1e-6));
    });

    // As the 13.08 replays record Haunt: the eye flies, stops and drops,
    // and as it ends the reveal source starts where it fell.
    const hauntEye = '/Game/Characters/BountyHunter/S0/Ability_E/'
        'Projectile_E_BountyHunter_Divebomb.Projectile_E_BountyHunter_Divebomb_C';
    const hauntReveal = '/Game/Characters/BountyHunter/S0/Ability_E/'
        'GameObject_BountyHunter_E_LoSReveal_Source_Reactivate.'
        'GameObject_BountyHunter_E_LoSReveal_Source_Reactivate_C';
    ReplayDocument haunt() => document(utility: [
          {
            'id': 3,
            'classPath': hauntEye,
            'owner': 'b',
            'spawnMs': 1000,
            'endMs': 3400,
            'position': [0, 0, 1400],
            'path': [
              [2500, 2000, 0, 2700],
              [3000, 2000, 0, 2300],
              [3300, 2000, 0, 2550],
            ],
          },
          {
            'id': 4,
            'classPath': hauntReveal,
            'owner': 'b',
            'spawnMs': 3400,
            'endMs': 4900,
            'position': [2000, 0, 2570],
          },
        ]);

    test("Haunt's eye has no reveal circle until it reveals", () {
      final frames = builder(haunt());
      ReplayFrame at(int t) => frames.frameAt(t, perspective: ReplayTeam.red);
      final landed = projection.toWorld(2000, 0);

      // Flying, then fallen and not yet revealing: the eye's icon, no circle.
      for (final t in [1800, 3200]) {
        final frame = at(t);
        expect(frame.abilities, isEmpty, reason: '$t');
        expect(frame.effects.whereType<ReplayFlight>().single.iconPath,
            AgentData.agents[AgentType.fade]!.abilities[2].iconPath);
      }
      final fallen = at(3200).effects.whereType<ReplayFlight>().single;
      expect((fallen.trail.last - landed).distance, lessThan(1e-6));

      // Revealing: Haunt's circle, centred where the eye fell.
      final revealing = at(3600);
      expect(revealing.effects.whereType<ReplayFlight>(), isEmpty);
      final circle = revealing.abilities.single;
      expect(circle.data.abilityData, isA<CircleAbility>());
      expect((circle.data.type, circle.data.index), (AgentType.fade, 2));
      final anchor = CoordinateSystem.virtualToWorld(storedAbilityAnchor(
        ability: circle.data.abilityData!,
        mapScale: Maps.mapScale[projection.map]!,
      ));
      expect((circle.position + anchor - landed).distance, lessThan(1e-6));
    });

    // Omen's Paranoia, cast from the origin along +x.
    const paranoia = '/Game/Characters/Wraith/S0/Ability_Q/'
        'Projectile_Wraith_Q_NearsightMissile.'
        'Projectile_Wraith_Q_NearsightMissile_C';
    ReplayDocument paranoiaCast({required int reachCm}) => document(utility: [
          {
            'id': 5,
            'classPath': paranoia,
            'owner': 'b',
            'spawnMs': 1000,
            'endMs': 2500,
            'position': [0, 0, 100],
            'yaw': 0,
            'path': [
              [2500, reachCm, 0, 100],
            ],
          },
        ]);

    test('Paranoia stays where it was cast and reaches as far as it flew', () {
      final frames = builder(paranoiaCast(reachCm: 2000));
      final frame = frames.frameAt(1750, perspective: ReplayTeam.red);
      final cast = projection.toWorld(0, 0);
      final head = projection.toWorld(1000, 0);

      // What a capture saves: Paranoia's icon at the cast point, its area
      // hidden, since a placed Paranoia can only draw its full length.
      final placed = frame.abilities.single;
      expect((placed.data.type, placed.data.index), (AgentType.omen, 1));
      final anchor = CoordinateSystem.virtualToWorld(storedAbilityAnchor(
        ability: placed.data.abilityData!,
        mapScale: Maps.mapScale[projection.map]!,
      ));
      expect((placed.position + anchor - cast).distance, lessThan(1e-6));
      expect(placed.visualState.showRangeFill, isFalse);

      // What the viewer adds: the area from the cast point to the head.
      final sweep = frame.effects.whereType<ReplaySweep>().single;
      expect(sweep.from, cast);
      expect((sweep.to - head).distance, lessThan(1e-6));
      expect(sweep.area.position, placed.position);
      expect(sweep.area.rotation, placed.rotation);
      expect(sweep.area.visualState.showRangeFill, isTrue);
      expect(sweep.opacity, 1);
    });

    test("Paranoia's reach stops at its full length and fades as it ends", () {
      final frames = builder(paranoiaCast(reachCm: 6000));
      ReplayFrame at(int t) => frames.frameAt(t, perspective: ReplayTeam.red);
      final cast = projection.toWorld(0, 0);
      final shape = AgentData.agents[AgentType.omen]!.abilities[1].abilityData
          as SquareAbility;
      final full = CoordinateSystem.virtualLengthInWorld(
          shape.height * Maps.mapScale[projection.map]!);

      // The head is past the full length by now.
      expect((projection.toWorld(5600, 0) - cast).distance, greaterThan(full));
      final late = at(2400).effects.whereType<ReplaySweep>().single;
      expect((late.to - cast).distance, closeTo(full, 1e-6));

      // Ended at 2500: the icon and the swept area fade out together.
      final leaving = at(2700);
      expect(leaving.abilities, isEmpty);
      final exit = leaving.effects.whereType<ReplayExit>().single;
      expect(exit.ability.visualState.showRangeFill, isFalse);
      expect(exit.centre, cast);
      final fading = leaving.effects.whereType<ReplaySweep>().single;
      expect(fading.opacity, closeTo(1 - exit.progress, 1e-9));
      expect(at(3100).effects, isEmpty);
    });

    test('a sweep is drawn from its icon to its head, on either side', () {
      CoordinateSystem(playAreaSize: const Size(1600, 900));
      final sweep = builder(paranoiaCast(reachCm: 2000))
          .frameAt(1750, perspective: ReplayTeam.red)
          .effects
          .whereType<ReplaySweep>()
          .single;
      const iconSide = 20.0;
      for (final isAttack in [true, false]) {
        final clip = ReplaySweepClipper(
          sweep: sweep,
          isAttack: isAttack,
          iconSide: iconSide,
        ).getClip(const Size(1600, 900));
        final from = replayScreenPoint(sweep.from, isAttack: isAttack);
        final to = replayScreenPoint(sweep.to, isAttack: isAttack);
        final along = (to - from) / (to - from).distance;
        Offset at(double pixels) => from + along * pixels;
        final reach = (to - from).distance;
        expect(reach, greaterThan(iconSide * 2), reason: '$isAttack');
        // The placed ability draws the icon; the sweep leaves it out.
        expect(clip.contains(from), isFalse, reason: '$isAttack');
        expect(clip.contains(at(iconSide)), isTrue, reason: '$isAttack');
        expect(clip.contains(at(reach - 1)), isTrue, reason: '$isAttack');
        expect(clip.contains(at(reach + 1)), isFalse, reason: '$isAttack');
        // No wider than the area: on Windows Skia masks a clip like this on
        // the CPU, and a mask the size of the canvas costs every frame.
        final halfWidth =
            CoordinateSystem.instance.worldHeightToScreen(sweep.halfWidth);
        final side = Offset(-along.dy, along.dx);
        expect(clip.contains(at(reach / 2) + side * (halfWidth - 1)), isTrue,
            reason: '$isAttack');
        expect(clip.contains(at(reach / 2) + side * (halfWidth + 3)), isFalse,
            reason: '$isAttack');
      }
    });
  });

  test('size conversions need no laid-out canvas, and match the canvas', () {
    for (final height in [700.0, 1440.0]) {
      final canvas = CoordinateSystem(
        playAreaSize: Size(height * 16 / 9, height),
      );
      const offset = Offset(17.5, 17.5);
      final viaCanvas = canvas.virtualOffsetToWorld(offset);
      final static = CoordinateSystem.virtualToWorld(offset);
      expect(static.dx, closeTo(viaCanvas.dx, 1e-9));
      expect(static.dy, closeTo(viaCanvas.dy, 1e-9));
      expect(CoordinateSystem.virtualLengthInWorld(30),
          closeTo(canvas.virtualLengthToWorld(30), 1e-9));
    }
  });

  group('playback', () {
    ReplayPlayback playback() => ReplayPlayback(
          document: document(),
          projection: projection,
          perspective: ReplayTeam.red,
        );

    test('speed is exact whatever the frame rate', () {
      final half = playback()
        ..speed = 0.5
        ..play();
      final start = half.timeMs;
      for (var i = 0; i < 60; i++) {
        half.advance(const Duration(microseconds: 16667));
      }
      expect(half.timeMs - start, inInclusiveRange(499, 501));
    });

    test('previous round goes to this round first, then the one before', () {
      final p = playback()..seek(70000);
      p.previousRound();
      expect(p.timeMs, 60000);
      p.previousRound();
      expect(p.timeMs, 0);
    });

    test('the spawn barriers are up only until they drop', () {
      // Round 1's barriers drop at 31 s; round 2 never recorded its drop.
      final p = ReplayPlayback(
        document: ReplayDocument.fromBytes(icrp(sampleJson())),
        projection: projection,
        perspective: ReplayTeam.red,
      );
      expect((p..seek(1000)).barriersUp, isTrue);
      expect((p..seek(30999)).barriersUp, isTrue);
      expect((p..seek(31000)).barriersUp, isFalse);
      expect((p..seek(60000)).barriersUp, isFalse);
      // Jumping to a round lands where play starts, barriers down.
      expect((p..seekRound(0)).barriersUp, isFalse);
    });

    ReplayDocument walkers(List<String> subjects) => document(
          players: [
            for (final subject in subjects)
              {'subject': subject, 'agentId': jett, 'team': 'Red'},
          ],
          movement: {
            // Everyone walks along x, 1 cm a millisecond.
            for (final subject in subjects)
              subject: [
                for (var t = 0; t <= 60000; t += 50)
                  [t, t.toDouble(), 0, 100, 0, 0]
              ],
          },
        );

    test('playing moves every player every frame', () {
      final subjects = ['p0', 'p1', 'p2', 'p3', 'p4', 'p5'];
      final playback = ReplayPlayback(
        document: walkers(subjects),
        projection: projection,
        perspective: ReplayTeam.red,
      )..play();
      Map<String, Offset> positions() => {
            for (final agent in playback.frame.agents) agent.id: agent.position,
          };
      final before = positions();
      playback.advance(const Duration(milliseconds: 10));
      final after = positions();
      expect(
        subjects.where(
            (s) => before['replay-player-$s'] != after['replay-player-$s']),
        hasLength(subjects.length),
      );
      // With no cone worker, each cone cuts its own.
      expect(playback.frame.cones, isEmpty);
    });

    test('cones are cut on a worker and drawn from their latest cut', () async {
      CoordinateSystem(playAreaSize: const Size(1600, 900));
      List<int> model(String side) =>
          File('assets/maps/sunset_svg_height_$side.json.gz').readAsBytesSync();
      final worker = await ReplayConeWorker.start(
        attackModel: Uint8List.fromList(model('attack')),
        defenseModel: Uint8List.fromList(model('defense')),
      );
      addTearDown(worker.dispose);
      final playback = ReplayPlayback(
        document: walkers(['p0']),
        projection: projection,
        perspective: ReplayTeam.red,
      );
      var arrived = 0;
      final cuts = ReplayConeCuts(
        worker: worker,
        map: projection.map,
        attackModel: SvgHeightVisibility.fromJson(
            jsonDecode(utf8.decode(gzip.decode(model('attack'))))
                as Map<String, dynamic>),
        defenseModel: SvgHeightVisibility.fromJson(
            jsonDecode(utf8.decode(gzip.decode(model('defense'))))
                as Map<String, dynamic>),
        coneLength: ReplayFrameBuilder.coneLength,
        apertureDegrees: 180,
        onCut: () {
          arrived++;
          playback.coneCutArrived();
        },
      );
      playback
        ..coneCuts = cuts
        ..seek(1000);

      // Asked for, not yet cut: no cone rather than a wrong one.
      final waiting = playback.frame.cones.values.single;
      expect(waiting.cut, isNull);
      while (arrived == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final cut = playback.frame.cones.values.single;
      expect(cut.cut!.cone!.polygon.length, greaterThanOrEqualTo(3));
      expect(cut.cut!.aim, cut.aim.placed,
          reason: 'paused: cut where they stand');

      // Moving on, the agent moves at once; the old cut is drawn carried
      // along to it until the next one arrives.
      playback.seek(1500);
      final moved = playback.frame.cones.values.single;
      expect(moved.cut!.id, cut.cut!.id);
      expect(moved.aim.origin, isNot(moved.cut!.aim.origin));
      while (arrived == 1) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final caughtUp = playback.frame.cones.values.single;
      expect(caughtUp.cut!.aim, caughtUp.aim.placed);
    });

    test('a worker whose models do not load says so', () async {
      await expectLater(
        ReplayConeWorker.start(
          attackModel: Uint8List.fromList([1, 2, 3]),
          defenseModel: Uint8List.fromList([4, 5, 6]),
        ),
        throwsStateError,
      );
    });

    test('playing stops at the end', () {
      final p = playback();
      p
        ..seek(p.durationMs - 10)
        ..play();
      p.advance(const Duration(seconds: 1));
      expect(p.timeMs, p.durationMs);
      expect(p.playing, isFalse);
    });
  });
}

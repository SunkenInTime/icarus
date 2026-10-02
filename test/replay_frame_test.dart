import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_frame.dart';
import 'package:icarus/replay/replay_map_projection.dart';
import 'package:icarus/replay/replay_playback.dart';

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

    test('playing moves a few players a frame; pausing shows all exactly', () {
      final subjects = ['p0', 'p1', 'p2', 'p3', 'p4', 'p5'];
      final doc = document(
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
      final playback = ReplayPlayback(
        document: doc,
        projection: projection,
        perspective: ReplayTeam.red,
      )..play();
      Map<String, Offset> positions() => {
            for (final agent in playback.frame.agents) agent.id: agent.position,
          };
      final before = positions();
      playback.advance(const Duration(milliseconds: 10));
      final after = positions();
      final moved = subjects
          .where((s) => before['replay-player-$s'] != after['replay-player-$s'])
          .length;
      expect(moved, 3);

      playback.pause();
      final exact = playback.frames
          .frameAt(playback.timeMs, perspective: ReplayTeam.red)
          .agents;
      expect(
        {for (final agent in playback.frame.agents) agent.id: agent.position},
        {for (final agent in exact) agent.id: agent.position},
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

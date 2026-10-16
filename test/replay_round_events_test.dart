import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_map_projection.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:icarus/replay/replay_weapons.dart';
import 'package:icarus/widgets/replay/replay_dock.dart';
import 'package:icarus/widgets/replay/replay_events.dart';
import 'package:icarus/widgets/replay/replay_roster.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'replay_test_support.dart';

const jett = 'add6443a-41bd-e414-f6ad-e58d267f4e95';
const omen = '8e253930-4c05-31dd-1b6c-968525494517';
const chamber = '22697a3d-45bf-8dd7-4fec-84a9e28c69d7';
const raze = 'f94c3b30-42be-e959-889c-5aa313dba261';

const vandal = '/Game/Equippables/Guns/Rifles/AK/AK.AK_C';
const headhunter = '/Game/Characters/Deadeye/S0/Ability_Q/Gun/'
    'Gun_Deadeye_Q_Pistol.Gun_Deadeye_Q_Pistol_C';

/// A utility actor of [asset] from [spawnMs] to [endMs], [owner]'s when
/// the replay names them.
Map<String, Object?> utility(
  String agentFolder,
  String asset,
  int spawnMs,
  int? endMs, {
  String? owner,
}) =>
    {
      'id': spawnMs,
      'classPath': '/Game/Characters/$agentFolder/S0/Ability_4/'
          '$asset.${asset}_C',
      'owner': owner,
      'spawnMs': spawnMs,
      'endMs': endMs,
      'position': [0, 0, 0],
    };

/// Round 1 (0–100 s): Jett plants B, Omen defuses, Blue wins. Round 2
/// (100–150 s): the spike detonates on A, Red wins. Red attacks both.
/// Round 1's abilities: Chamber's trap in the buy, set off at 52 s; Omen's
/// smoke thrown at 45 s; Jett's two smokes 400 ms apart at 50 s.
ReplayDocument document() => ReplayDocument.fromBytes(icrp({
      ...sampleJson(),
      'match': {
        'id': 'match',
        'mapPath': '/Game/Maps/Juliett/Juliett',
        'build': '++Ares-Core+release-13.00',
        'durationMs': 150000,
      },
      'players': [
        {'subject': 'a', 'agentId': jett, 'team': 'Red'},
        {'subject': 'd', 'agentId': raze, 'team': 'Red'},
        {'subject': 'b', 'agentId': omen, 'team': 'Blue'},
        {'subject': 'c', 'agentId': chamber, 'team': 'Blue'},
      ],
      'rounds': [
        {
          'index': 0,
          'startMs': 0,
          'combatStartMs': 30000,
          'endMs': 100000,
          'attackingTeam': 'Red',
          'winningTeam': 'Blue',
          'endReason': 'defused',
          'plant': {'timeMs': 60000, 'site': 'B', 'subject': 'a'},
          'defuse': {'timeMs': 90000, 'subject': 'b'},
        },
        {
          'index': 1,
          'startMs': 100000,
          'combatStartMs': 105000,
          'endMs': 150000,
          'attackingTeam': 'Red',
          'winningTeam': 'Red',
          'endReason': 'detonated',
          'plant': {'timeMs': 110000, 'site': 'A', 'subject': 'd'},
          'detonateMs': 145000,
        },
      ],
      'kills': [
        {
          'timeMs': 40000,
          'victim': 'd',
          'killer': 'b',
          'assists': ['c'],
          'damageSource': vandal,
        },
        {
          'timeMs': 70000,
          'victim': 'a',
          'killer': 'c',
          'damageSource': headhunter,
        },
        // A fall: no killer, no source.
        {'timeMs': 120000, 'victim': 'b'},
      ],
      'utility': [
        utility('Deadeye', 'GameObject_Deadeye_E_Trap', 5000, null,
            owner: 'c'),
        utility('Wraith', 'Projectile_Wraith_4_Smoke', 45000, 46200,
            owner: 'b'),
        // The replay names no owner; Omen is the only Omen.
        utility('Wraith', 'Zone_Wraith_4_Smoke', 46000, 61000),
        // Nobody plays Breach.
        utility('Breach', 'Projectile_Breach_4_FusionBlast', 47000, 48000),
        utility('Wushu', 'Projectile_Wushu_4_Smoke', 50000, 51000,
            owner: 'a'),
        utility('Wushu', 'Projectile_Wushu_4_Smoke', 50400, 51400,
            owner: 'a'),
        utility('Wushu', 'GameObject_Wushu_4_SmokeZone', 50900, 55000,
            owner: 'a'),
        // The trap going off.
        utility('Deadeye', 'Patch_Deadeye_E_Slow_Large', 52000, 59000,
            owner: 'c'),
      ],
      'vitals': {},
    }));

ReplayPlayback playback() => ReplayPlayback(
      document: document(),
      projection:
          ReplayMapProjection.forMapPath('/Game/Maps/Juliett/Juliett')!,
      perspective: ReplayTeam.red,
    );

Future<void> pumpBody(WidgetTester tester, Widget child) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      child: ShadApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 880, height: 700, child: child),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// An image of [path] in an event line.
Finder asset(String path) => find.descendant(
      of: find.byType(ReplayEventLine),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            widget.image is AssetImage &&
            (widget.image as AssetImage).assetName == path,
      ),
    );

/// The spike's art in an event line.
Finder spike() => find.descendant(
      of: find.byType(ReplayEventLine),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is SvgPicture &&
            widget.bytesLoader is SvgAssetLoader &&
            (widget.bytesLoader as SvgAssetLoader).assetName ==
                'assets/spike.svg',
      ),
    );

List<ReplayEventKind> shownKinds(WidgetTester tester) => [
      for (final line
          in tester.widgetList<ReplayEventLine>(find.byType(ReplayEventLine)))
        line.event.kind,
    ];

void main() {
  group('kill sources', () {
    AgentData agent(AgentType type) => AgentData.agents[type]!;

    test('a gun is not an ability', () {
      expect(replayKillAbility(vandal, AgentType.chamber), isNull);
    });

    test('an ability gun maps through its slot folder', () {
      expect(replayKillAbility(headhunter, AgentType.chamber),
          same(agent(AgentType.chamber).abilities[1]));
      expect(
        replayKillAbility(
            '/Game/Characters/Wushu/S0/Ability_X/Dagger.Dagger_C',
            AgentType.jett),
        same(agent(AgentType.jett).abilities[3]),
      );
    });

    test("Miks's ultimate is his fifth ability", () {
      expect(
        replayKillAbility(
            '/Game/Characters/Iris/S0/Ability_X/Wave.Wave_C', AgentType.miks),
        same(agent(AgentType.miks).abilities[4]),
      );
    });

    test('a catalogued actor is its ability', () {
      expect(
        replayKillAbility(
            '/Game/Characters/Clay/S0/Ability_4/Projectile_Clay_4_'
            'Projectile_Primary.Projectile_Clay_4_Projectile_Primary_C',
            AgentType.raze),
        same(agent(AgentType.raze).abilities[2]),
      );
    });

    test('an unchecked slot or a missing source is unknown', () {
      expect(
        replayKillAbility(
            '/Game/Characters/Hunter/S0/Ability_E/Bolt.Bolt_C',
            AgentType.sova),
        isNull,
      );
      expect(replayKillAbility(null, AgentType.sova), isNull);
    });
  });

  testWidgets('round chips show how each round ended', (tester) async {
    final p = playback();
    await pumpBody(tester, Center(child: ReplayDock(playback: p)));

    expect(find.byIcon(LucideIcons.scissors), findsOneWidget);
    expect(find.byIcon(LucideIcons.flame), findsOneWidget);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('1')));
    await tester.pumpAndSettle();
    expect(find.text('Round 1 · Lost · Spike defused on B'), findsOneWidget);

    await mouse.moveTo(tester.getCenter(find.text('2')));
    await tester.pumpAndSettle();
    expect(find.text('Round 2 · Won · Spike detonated on A'), findsOneWidget);
  });

  testWidgets('the killfeed shows what killed, and the spike', (tester) async {
    final p = playback()..seek(65000);
    await pumpBody(
      tester,
      Align(alignment: Alignment.topLeft, child: ReplayRoster(playback: p)),
    );

    expect(shownKinds(tester), [ReplayEventKind.plant, ReplayEventKind.kill]);
    expect(asset('assets/weapons/vandal.png'), findsOneWidget);
    // The assist, beside Omen's kill.
    expect(asset('assets/agents/Chamber/icon.webp'), findsOneWidget);

    p.seek(95000);
    await tester.pump();
    expect(shownKinds(tester), [
      ReplayEventKind.defuse,
      ReplayEventKind.kill,
      ReplayEventKind.plant,
      ReplayEventKind.kill,
    ]);
    expect(asset(AgentData.agents[AgentType.chamber]!.abilities[1].iconPath),
        findsOneWidget);
    // The plant draws Valorant's spike, beside its site.
    expect(spike(), findsOneWidget);
    expect(find.text('B'), findsOneWidget);

    // Clicking the plant goes to 2 s before it.
    await tester.tap(spike());
    await tester.pump();
    expect(p.timeMs, 58000);
  });

  test('a death after the round ends, before the next starts, is its own',
      () {
    final withLateKill = ReplayDocument.fromBytes(icrp({
      ...sampleJson(),
      'rounds': [
        {'index': 0, 'startMs': 0, 'endMs': 92000, 'attackingTeam': 'Red'},
        {
          'index': 1,
          'startMs': 100000,
          'endMs': 150000,
          'attackingTeam': 'Red',
        },
      ],
      'kills': [
        {'timeMs': 95000, 'victim': 'b', 'killer': 'a'},
      ],
    }));
    // Past the round's end, in its post-round.
    expect(withLateKill.rounds.first.contains(95000), isFalse);
    expect(
      replayRoundEvents(withLateKill, withLateKill.rounds.first)
          .map((event) => event.timeMs),
      [95000],
    );
    expect(
      replayRoundEvents(withLateKill, withLateKill.rounds.last),
      isEmpty,
    );
  });

  testWidgets('a death with no killer or source reads as a death',
      (tester) async {
    final p = playback()..seek(125000);
    await pumpBody(
      tester,
      Align(alignment: Alignment.topLeft, child: ReplayRoster(playback: p)),
    );
    expect(
      find.descendant(
        of: find.byType(ReplayEventLine),
        matching: find.byIcon(LucideIcons.skull),
      ),
      findsOneWidget,
    );
    expect(asset('assets/agents/Omen/icon.webp'), findsOneWidget);
  });

  testWidgets('a kill with four assists fits its row, the victim at the edge',
      (tester) async {
    final crowded = ReplayDocument.fromBytes(icrp({
      ...sampleJson(),
      'players': [
        for (final (subject, agentId, team) in [
          ('k', jett, 'Red'),
          ('a1', raze, 'Red'),
          ('a2', chamber, 'Red'),
          ('a3', raze, 'Red'),
          ('a4', chamber, 'Red'),
          ('v', omen, 'Blue'),
        ])
          {'subject': subject, 'agentId': agentId, 'team': team},
      ],
      'rounds': [
        {
          'index': 0,
          'startMs': 0,
          'combatStartMs': 1000,
          'endMs': 60000,
          'attackingTeam': 'Red',
        },
      ],
      'kills': [
        {
          'timeMs': 5000,
          'victim': 'v',
          'killer': 'k',
          'assists': ['a1', 'a2', 'a3', 'a4'],
          'damageSource': '/Game/Equippables/Guns/HvyMachineGuns/HMG/'
              'HMG.HMG_C',
        },
      ],
    }));
    final p = ReplayPlayback(
      document: crowded,
      projection:
          ReplayMapProjection.forMapPath('/Game/Maps/Juliett/Juliett')!,
      perspective: ReplayTeam.red,
    )..seek(10000);
    await pumpBody(
      tester,
      Align(alignment: Alignment.topLeft, child: ReplayRoster(playback: p)),
    );

    // A layout overflow would have failed the pump.
    final line = tester.getRect(find.byType(ReplayEventLine));
    final victim = tester.getRect(asset('assets/agents/Omen/icon.webp'));
    expect(line.width, greaterThan(ReplayRoster.width - 40));
    expect(victim.right, closeTo(line.right, 2));
    expect(asset('assets/weapons/odin.png'), findsOneWidget);
  });

  testWidgets('hovering a scrubber mark shows its killfeed line',
      (tester) async {
    final p = playback()..seek(35000);
    await pumpBody(tester, Center(child: ReplayDock(playback: p)));

    final track = tester.getRect(find.byWidgetPredicate((widget) =>
        widget is CustomPaint &&
        widget.painter.runtimeType.toString() == '_ScrubberPainter'));
    Offset at(int ms) => Offset(track.left + track.width * ms / 100000,
        track.center.dy);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(at(60000) + const Offset(4, 0));
    await tester.pump();

    expect(shownKinds(tester), [ReplayEventKind.plant]);
    final card = tester.getRect(find.byType(ReplayEventLine));
    expect(card.bottom, lessThanOrEqualTo(track.top));
    expect(card.center.dx, closeTo(at(60000).dx, 20));

    await mouse.moveTo(at(90000));
    await tester.pump();
    expect(shownKinds(tester), [ReplayEventKind.defuse]);

    await mouse.moveTo(at(20000));
    await tester.pump();
    expect(find.byType(ReplayEventLine), findsNothing);

    await mouse.moveTo(at(70000));
    await tester.pump();
    expect(shownKinds(tester), [ReplayEventKind.kill]);
    expect(asset(AgentData.agents[AgentType.chamber]!.abilities[1].iconPath),
        findsOneWidget);

    await mouse.moveTo(Offset.zero);
    await tester.pump();
    expect(find.byType(ReplayEventLine), findsNothing);
  });

  test('one cast is one ability use, at the moment it was cast', () {
    final doc = document();
    String name(AgentType agent, int index) =>
        AgentData.agents[agent]!.abilities[index].name;
    expect(
      [
        for (final event in replayRoundEvents(doc, doc.rounds.first))
          if (event.kind == ReplayEventKind.ability)
            (event.timeMs, event.subject, event.ability!.name),
      ],
      [
        // The trap, once: going off is not another use.
        (5000, 'c', name(AgentType.chamber, 0)),
        // The smoke thrown, not again where it lands.
        (45000, 'b', name(AgentType.omen, 2)),
        // Two smokes thrown one after the other are two.
        (50000, 'a', name(AgentType.jett, 0)),
        (50400, 'a', name(AgentType.jett, 0)),
      ],
    );
  });

  group('the event filter', () {
    testWidgets('picks what the killfeed lists', (tester) async {
      final p = playback()..seek(35000);
      await pumpBody(
        tester,
        Align(alignment: Alignment.topLeft, child: ReplayRoster(playback: p)),
      );
      // Ability uses start hidden, and the trap is all that has happened.
      expect(find.byType(ReplayEventLine), findsNothing);
      expect(find.text('No kills yet this round'), findsOneWidget);

      await tester.tap(find.text('Abilities'));
      await tester.pump();
      expect(shownKinds(tester), [ReplayEventKind.ability]);
      // Placed in the buy, before the barriers dropped.
      expect(find.text('-0:25'), findsOneWidget);
      expect(find.text(AgentData.agents[AgentType.chamber]!.abilities[0].name),
          findsOneWidget);

      p.seek(65000);
      await tester.pump();
      expect(shownKinds(tester), [
        ReplayEventKind.plant,
        ReplayEventKind.ability,
        ReplayEventKind.ability,
        ReplayEventKind.ability,
        ReplayEventKind.kill,
        ReplayEventKind.ability,
      ]);

      await tester.tap(find.text('Kills'));
      await tester.tap(find.text('Abilities'));
      await tester.pump();
      expect(shownKinds(tester), [ReplayEventKind.plant]);

      await tester.tap(find.text('Spike'));
      await tester.pump();
      expect(find.byType(ReplayEventLine), findsNothing);
      expect(find.text('Choose what to show'), findsOneWidget);
    });

    testWidgets('picks what the scrubber marks', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final p = playback()..seek(35000);
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: ShadApp(
          home: Scaffold(body: Center(child: ReplayDock(playback: p))),
        ),
      ));
      await tester.pump();

      final scrubber = find.byWidgetPredicate((widget) =>
          widget is CustomPaint &&
          widget.painter.runtimeType.toString() == '_ScrubberPainter');
      final track = tester.getRect(scrubber);
      Offset at(int ms) =>
          Offset(track.left + track.width * ms / 100000, track.center.dy);
      List<ReplayEventKind> marked() => [
            for (final event in (tester.widget<CustomPaint>(scrubber).painter
                    as dynamic)
                .events as List<ReplayRoundEvent>)
              event.kind,
          ];
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);

      expect(marked(), isNot(contains(ReplayEventKind.ability)));
      await mouse.moveTo(at(45000));
      await tester.pump();
      expect(find.byType(ReplayEventLine), findsNothing);

      container.read(replayEventFiltersProvider.notifier).state = {
        ReplayEventFilter.abilities,
      };
      await tester.pump();
      expect(marked(), [
        for (var i = 0; i < 4; i++) ReplayEventKind.ability,
      ]);
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      await mouse.moveTo(at(45000));
      await tester.pump();
      expect(shownKinds(tester), [ReplayEventKind.ability]);
      expect(find.text(AgentData.agents[AgentType.omen]!.abilities[2].name),
          findsOneWidget);
    });
  });
}

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/active_page_live_sync_provider.dart';
import 'package:icarus/providers/collab/lineup_editing_presence_provider.dart';
import 'package:icarus/providers/collab/strategy_presence_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/widgets/dialogs/lineup_panel_dialog.dart';
import 'package:icarus/widgets/lineup_editors_notice.dart';
import 'package:icarus/widgets/strategy_presence.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _FixedPresence extends StrategyPresenceNotifier {
  _FixedPresence(this._state);

  final PresenceRoomState _state;

  @override
  PresenceRoomState build() => _state;
}

PresencePeer _peer(
  String sid,
  String uid,
  String name,
  String role, {
  PresenceEditing? editing,
}) =>
    PresencePeer(
      sid: sid,
      uid: uid,
      name: name,
      avatarUrl: null,
      role: role,
      cursor: null,
      editing: editing,
    );

/// The editor showing page p1, without the session's cloud machinery.
class _FixedSession extends StrategyPageSessionNotifier {
  @override
  StrategyPageSessionState build() => const StrategyPageSessionState(
        activePageId: 'p1',
        availablePageIds: ['p1'],
        transitionState: PageTransitionState.idle,
        isApplyingPage: false,
      );
}

/// Two lineups from two origins landing on one spot, all lineup group g1.
LineUpGraph _landingGraph() {
  LineUpOrigin origin(String id) => LineUpOrigin(
        id: id,
        agent: PlacedAgent(
          id: '$id-agent',
          type: AgentType.breach,
          position: const Offset(20, 20),
        ),
      );
  return LineUpGraph(
    origins: [origin('origin-1'), origin('origin-2')],
    landings: [
      LineUpLanding(
        id: 'landing',
        ability: PlacedAbility(
          id: 'landing-ability',
          data: AgentData.agents[AgentType.breach]!.abilities.first,
          position: const Offset(50, 50),
        ),
      ),
    ],
    links: [
      LineUpLink(id: 'link-1', originId: 'origin-1', landingId: 'landing'),
      LineUpLink(id: 'link-2', originId: 'origin-2', landingId: 'landing'),
    ],
  );
}

/// An editor on page p1 whose landing spot opens the lineup panel.
ProviderContainer _panelContainer(PresenceRoomState presence) {
  final container = ProviderContainer(overrides: [
    strategyPresenceProvider.overrideWith(() => _FixedPresence(presence)),
    strategyPageSessionProvider.overrideWith(_FixedSession.new),
  ]);
  container.read(lineUpProvider.notifier).fromHive(_landingGraph());
  container.read(activePageLiveSyncProvider.notifier).noteLineupGroups('p1', {
    'origin-1': 'g1',
    'origin-2': 'g1',
    'landing': 'g1',
    'link-1': 'g1',
    'link-2': 'g1',
  });
  return container;
}

Future<void> _openPanel(
    WidgetTester tester, ProviderContainer container) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: ShadApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ShadButton(
            onPressed: () => showLineUpPanel(context, landingId: 'landing'),
            child: const Text('Open panel'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('Open panel'));
  await tester.pumpAndSettle();
  expect(find.byType(LineUpPanelDialog), findsOneWidget);
}

Widget _app(PresenceRoomState state, Widget child) => ProviderScope(
      overrides: [
        strategyPresenceProvider.overrideWith(() => _FixedPresence(state)),
      ],
      child: ShadApp(home: Scaffold(body: Center(child: child))),
    );

void main() {
  testWidgets('shows nothing when you are alone', (tester) async {
    await tester.pumpWidget(_app(
      const PresenceRoomState(
        connection: PresenceConnection.live,
        selfUid: 'me',
      ),
      const StrategyPresenceAvatars(),
    ));
    expect(
        find.byKey(const ValueKey('strategy-presence-avatars')), findsNothing);
  });

  testWidgets('hovering an avatar names the person and says when they view',
      (tester) async {
    await tester.pumpWidget(_app(
      PresenceRoomState(
        connection: PresenceConnection.live,
        selfUid: 'me',
        peers: {
          's1': _peer('s1', 'ben', 'Ben', 'viewer'),
          's2': _peer('s2', 'me', 'Me elsewhere', 'owner'),
        },
      ),
      const StrategyPresenceAvatars(),
    ));

    final avatars = find.byKey(const ValueKey('strategy-presence-avatars'));
    expect(avatars, findsOneWidget);
    // One person: your own other window is not someone else.
    expect(tester.getSize(avatars).width, 24);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(avatars));
    await tester.pumpAndSettle();
    expect(find.text('Ben (viewing)'), findsOneWidget);
  });

  testWidgets('more than four people collapse into a count', (tester) async {
    await tester.pumpWidget(_app(
      PresenceRoomState(
        connection: PresenceConnection.live,
        selfUid: 'me',
        peers: {
          for (var i = 0; i < 6; i++)
            's$i': _peer('s$i', 'u$i', 'Player $i', 'editor'),
        },
      ),
      const StrategyPresenceAvatars(),
    ));
    expect(find.text('+2'), findsOneWidget);
  });

  test('a person has one color everywhere', () {
    expect(presenceColorFor('0123456789abcdef01234567'),
        presenceColorFor('0123456789abcdef01234567'));
    // Pinned so a change to the hash (which would recolor everyone) is
    // deliberate.
    expect(
      [
        for (final uid in ['a', 'b', 'c', 'd', 'e']) presenceColorFor(uid)
      ].toSet(),
      hasLength(Settings.presenceColors.length),
    );
  });

  group('lineUpEditorsText', () {
    final sam = _peer('s1', 'sam', 'Sam', 'editor');
    final ana = _peer('s2', 'ana', 'Ana', 'editor');
    final ben = _peer('s3', 'ben', 'Ben', 'editor');
    final cy = _peer('s4', 'cy', 'Cy', 'editor');

    test('names one editor', () {
      expect(lineUpEditorsText([sam]), 'Sam is editing this lineup right now.');
      expect(lineUpEditorsText([sam], lineups: true),
          'Sam is editing these lineups right now.');
    });

    test('names two editors', () {
      expect(lineUpEditorsText([sam, ana]),
          'Sam and Ana are editing this lineup right now.');
      expect(lineUpEditorsText([sam, ana], lineups: true),
          'Sam and Ana are editing these lineups right now.');
    });

    test('counts the rest past one editor when there are three or more', () {
      expect(lineUpEditorsText([sam, ana, ben]),
          'Sam and 2 others are editing this lineup right now.');
      expect(lineUpEditorsText([sam, ana, ben, cy], lineups: true),
          'Sam and 3 others are editing these lineups right now.');
    });
  });

  group('lineup panel', () {
    const sams = PresenceEditing(pageId: 'p1', groupIds: {'g1'});

    testWidgets('says who else is editing the lineups of its spot',
        (tester) async {
      final container = _panelContainer(PresenceRoomState(
        connection: PresenceConnection.live,
        selfUid: 'me',
        peers: {'s1': _peer('s1', 'sam', 'Sam', 'editor', editing: sams)},
      ));
      addTearDown(container.dispose);
      await _openPanel(tester, container);
      expect(
        find.text('Sam is editing these lineups right now.'),
        findsOneWidget,
      );
    });

    testWidgets('says nothing when no one else edits its lineups',
        (tester) async {
      final container = _panelContainer(PresenceRoomState(
        connection: PresenceConnection.live,
        selfUid: 'me',
        peers: {
          // Another group, the same group on another page, and you.
          's1': _peer('s1', 'sam', 'Sam', 'editor',
              editing: const PresenceEditing(pageId: 'p1', groupIds: {'g2'})),
          's2': _peer('s2', 'ana', 'Ana', 'editor',
              editing: const PresenceEditing(pageId: 'p2', groupIds: {'g1'})),
          's3': _peer('s3', 'me', 'Me elsewhere', 'editor', editing: sams),
          's4': _peer('s4', 'ben', 'Ben', 'editor'),
        },
      ));
      addTearDown(container.dispose);
      await _openPanel(tester, container);
      expect(find.byType(LineUpEditorsNotice), findsOneWidget);
      expect(find.textContaining('editing'), findsNothing);
    });

    testWidgets('counts as editing its spot while it is open', (tester) async {
      final container = _panelContainer(const PresenceRoomState(
        connection: PresenceConnection.live,
        selfUid: 'me',
      ));
      addTearDown(container.dispose);
      expect(container.read(openLineUpItemsProvider), isEmpty);

      await _openPanel(tester, container);
      expect(container.read(openLineUpItemsProvider).values, [
        {'landing'},
      ]);
      expect(
        container.read(myLineupEditingProvider),
        const PresenceEditing(pageId: 'p1', groupIds: {'g1'}),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(LineUpPanelDialog), findsNothing);
      expect(container.read(openLineUpItemsProvider), isEmpty);
      expect(container.read(myLineupEditingProvider), isNull);
    });
  });
}

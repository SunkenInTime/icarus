import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/presence/presence_models.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/collab/active_page_live_sync_provider.dart';
import 'package:icarus/providers/collab/lineup_editing_presence_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/editor_operation_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';

/// The editor showing page p1, without the session's cloud machinery.
class _FixedSession extends StrategyPageSessionNotifier {
  @override
  StrategyPageSessionState build() => const StrategyPageSessionState(
        activePageId: 'p1',
        availablePageIds: ['p1', 'p2'],
        transitionState: PageTransitionState.idle,
        isApplyingPage: false,
      );
}

/// The role of whoever has the strategy open.
final _role = StateProvider<String>((ref) => 'editor');

/// Two lineups, each from its own origin to its own landing: two groups.
LineUpGraph _graph() {
  final ability = AgentData.agents[AgentType.breach]!.abilities.first;
  LineUpOrigin origin(String id) => LineUpOrigin(
        id: id,
        agent: PlacedAgent(
          id: '$id-agent',
          type: AgentType.breach,
          position: const Offset(20, 20),
        ),
      );
  LineUpLanding landing(String id) => LineUpLanding(
        id: id,
        ability: PlacedAbility(
          id: '$id-ability',
          data: ability,
          position: const Offset(50, 50),
        ),
      );
  return LineUpGraph(
    origins: [origin('origin-a'), origin('origin-b')],
    landings: [landing('landing-a'), landing('landing-b')],
    links: [
      LineUpLink(id: 'link-a', originId: 'origin-a', landingId: 'landing-a'),
      LineUpLink(id: 'link-b', originId: 'origin-b', landingId: 'landing-b'),
    ],
  );
}

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(overrides: [
      strategyPageSessionProvider.overrideWith(_FixedSession.new),
      currentStrategyCapabilitiesProvider.overrideWith(
        (ref) => StrategyCapabilities.fromCloudRole(ref.watch(_role)),
      ),
    ]);
    addTearDown(container.dispose);
    container.read(lineUpProvider.notifier).fromHive(_graph());
    container.read(activePageLiveSyncProvider.notifier)
      ..noteLineupGroups('p1', {
        'origin-a': 'group-a',
        'landing-a': 'group-a',
        'link-a': 'group-a',
        'origin-b': 'group-b',
        'landing-b': 'group-b',
        'link-b': 'group-b',
      })
      // The same lineups on a duplicated page are another page's groups.
      ..noteLineupGroups('p2', {'landing-a': 'group-a2'});
  });

  PresenceEditing? editing() => container.read(myLineupEditingProvider);

  test('nothing edited is null', () {
    expect(editing(), isNull);
  });

  test('a held lineup spot is editing its group', () {
    container.read(editorPointersProvider.notifier).holdEntity(1, 'landing-a');
    expect(
      editing(),
      const PresenceEditing(pageId: 'p1', groupIds: {'group-a'}),
    );
  });

  test('held items that are not lineups are ignored', () {
    final pointers = container.read(editorPointersProvider.notifier);
    pointers.holdEntity(1, 'some-agent');
    expect(editing(), isNull);
    pointers.holdEntity(1, 'origin-b');
    expect(
      editing(),
      const PresenceEditing(pageId: 'p1', groupIds: {'group-b'}),
    );
  });

  test('placing from a pinned spot is editing its group', () {
    container.read(lineUpProvider.notifier).startFromOrigin('origin-b');
    expect(
      editing(),
      const PresenceEditing(pageId: 'p1', groupIds: {'group-b'}),
    );
    container.read(lineUpProvider.notifier).startToLanding('landing-a');
    expect(
      editing(),
      const PresenceEditing(pageId: 'p1', groupIds: {'group-a'}),
    );
    // A fresh lineup belongs to no group yet.
    container.read(lineUpProvider.notifier).startFresh();
    expect(editing(), isNull);
  });

  test('an open dialog is editing the groups of the items it shows', () {
    final open = container.read(openLineUpItemsProvider.notifier);
    final panel = Object();
    final editor = Object();
    open.open(panel, {'landing-a'});
    expect(
      editing(),
      const PresenceEditing(pageId: 'p1', groupIds: {'group-a'}),
    );
    open.open(editor, {'link-b', 'not-a-lineup'});
    expect(
      editing(),
      const PresenceEditing(pageId: 'p1', groupIds: {'group-a', 'group-b'}),
    );
    open.close(panel);
    expect(
      editing(),
      const PresenceEditing(pageId: 'p1', groupIds: {'group-b'}),
    );
    open.close(editor);
    expect(container.read(openLineUpItemsProvider), isEmpty);
    expect(editing(), isNull);
  });

  test('a reader who can only view edits nothing they hold or open', () {
    container.read(_role.notifier).state = 'viewer';
    container.read(editorPointersProvider.notifier).holdEntity(1, 'landing-a');
    container.read(openLineUpItemsProvider.notifier).open(Object(), {
      'link-b',
    });
    expect(editing(), isNull);

    // Made an editor while still holding and looking: now it is editing.
    container.read(_role.notifier).state = 'editor';
    expect(
      editing(),
      const PresenceEditing(pageId: 'p1', groupIds: {'group-a', 'group-b'}),
    );
  });

  test('held, placed and open items together name each group once', () {
    container.read(editorPointersProvider.notifier).holdEntity(1, 'link-a');
    container.read(lineUpProvider.notifier).startToLanding('landing-a');
    container
        .read(openLineUpItemsProvider.notifier)
        .open(Object(), {'origin-b'});
    expect(
      editing(),
      const PresenceEditing(pageId: 'p1', groupIds: {'group-a', 'group-b'}),
    );
  });

  test('a group learned while a dialog is open is edited from then on', () {
    container
        .read(openLineUpItemsProvider.notifier)
        .open(Object(), {'link-new'});
    expect(editing(), isNull);
    // The lineup's group arrives (its first sync, or the page redrawn from
    // the server) while the dialog stays open.
    container
        .read(activePageLiveSyncProvider.notifier)
        .noteLineupGroups('p1', {'link-new': 'group-new'});
    expect(
      editing(),
      const PresenceEditing(pageId: 'p1', groupIds: {'group-new'}),
    );
  });

  test('a dialog edits the groups of the page it opened on, only there', () {
    container
        .read(openLineUpItemsProvider.notifier)
        .open(Object(), {'landing-a', 'landing-b'});
    final session = container.read(strategyPageSessionProvider.notifier);
    session.setStateForTest(
      container.read(strategyPageSessionProvider).copyWith(activePageId: 'p2'),
    );
    // Page 2 has lineups under the same ids, in other groups; the dialog
    // still shows page 1's, so it edits nothing here.
    expect(editing(), isNull);

    container
        .read(openLineUpItemsProvider.notifier)
        .open(Object(), {'landing-a'});
    expect(
      editing(),
      const PresenceEditing(pageId: 'p2', groupIds: {'group-a2'}),
    );
    session.setStateForTest(
      container
          .read(strategyPageSessionProvider)
          .copyWith(clearActivePageId: true),
    );
    expect(editing(), isNull);
  });
}

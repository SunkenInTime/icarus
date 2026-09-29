import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/collab/strategy_presence_provider.dart';
import 'package:icarus/widgets/dialogs/delete_page_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _FixedPresence extends StrategyPresenceNotifier {
  _FixedPresence(this._state);

  final PresenceRoomState _state;

  @override
  PresenceRoomState build() => _state;
}

PresencePeer _peer(String uid, String name, String? pageId) => PresencePeer(
      sid: 'sid-$uid',
      uid: uid,
      name: name,
      avatarUrl: null,
      role: 'editor',
      cursor:
          pageId == null ? null : PresenceCursor(pageId: pageId, x: 0, y: 0),
    );

PresenceRoomState _room(List<PresencePeer> peers) => PresenceRoomState(
      connection: PresenceConnection.live,
      selfUid: 'me',
      peers: {for (final peer in peers) peer.sid: peer},
    );

void main() {
  /// Opens the delete confirmation for page-1 and returns its answer once
  /// [answer] (a button label) is tapped.
  Future<bool?> confirm(
    WidgetTester tester,
    PresenceRoomState room, {
    required String expectContent,
    required String answer,
  }) async {
    bool? confirmed;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        strategyPresenceProvider.overrideWith(() => _FixedPresence(room)),
      ],
      child: ShadApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => Center(
              child: ShadButton(
                onPressed: () async => confirmed = await confirmDeletePage(
                  context,
                  ref,
                  pageId: 'page-1',
                  pageName: 'A exec',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text("Delete 'A exec'?"), findsOneWidget);
    expect(find.text(expectContent), findsOneWidget);
    await tester.tap(find.text(answer));
    await tester.pumpAndSettle();
    return confirmed;
  }

  const plain =
      'Are you sure you want to delete this page? This action cannot be '
      'undone.';

  testWidgets('with nobody else on the page, asks as it always has',
      (tester) async {
    final room = _room([
      _peer('alex', 'Alex', 'page-2'),
      _peer('sam', 'Sam', null),
      // Your own other window is not a teammate.
      _peer('me', 'Me', 'page-1'),
    ]);

    expect(
      await confirm(tester, room, expectContent: plain, answer: 'Delete'),
      isTrue,
    );
    expect(find.text('Delete anyway'), findsNothing);
  });

  testWidgets('says who is on the page, and deleting anyway still deletes',
      (tester) async {
    final room = _room([_peer('alex', 'Alex', 'page-1')]);

    expect(
      await confirm(
        tester,
        room,
        expectContent: 'Alex is on this page right now. Delete it anyway? '
            'This action cannot be undone.',
        answer: 'Delete anyway',
      ),
      isTrue,
    );
  });

  testWidgets('cancelling a warned delete keeps the page', (tester) async {
    final room = _room([
      _peer('alex', 'Alex', 'page-1'),
      _peer('sam', 'Sam', 'page-1'),
    ]);

    expect(
      await confirm(
        tester,
        room,
        expectContent: 'Alex and Sam are on this page right now. Delete it '
            'anyway? This action cannot be undone.',
        answer: 'Cancel',
      ),
      isFalse,
    );
  });

  testWidgets('a crowd is counted', (tester) async {
    final room = _room([
      _peer('alex', 'Alex', 'page-1'),
      _peer('sam', 'Sam', 'page-1'),
      _peer('kim', 'Kim', 'page-1'),
      _peer('lee', 'Lee', 'page-1'),
    ]);

    await confirm(
      tester,
      room,
      expectContent: 'Alex, Sam and 2 others are on this page right now. '
          'Delete it anyway? This action cannot be undone.',
      answer: 'Cancel',
    );
  });
}

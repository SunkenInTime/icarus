import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/collab/strategy_presence_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/dialogs/delete_page_dialog.dart';
import 'package:icarus/widgets/strategy_presence.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _FixedPresence extends StrategyPresenceNotifier {
  _FixedPresence(this._state);

  final PresenceRoomState _state;

  @override
  PresenceRoomState build() => _state;
}

class _Strategy extends StrategyProvider {
  _Strategy(this.source);

  final StrategySource source;

  @override
  StrategyState build() => StrategyState(
        strategyId: 'strategy-a',
        strategyName: 'Strategy A',
        source: source,
        isOpen: true,
      );
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
    StrategySource source = StrategySource.cloud,
  }) async {
    bool? confirmed;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        strategyPresenceProvider.overrideWith(() => _FixedPresence(room)),
        strategyProvider.overrideWith(() => _Strategy(source)),
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

  const plain = 'Are you sure you want to delete this page? You can restore '
      'it from Recently deleted for 30 days.';

  testWidgets(
      'a local page is gone for good, and the dialog says so, as it always has',
      (tester) async {
    expect(
      await confirm(
        tester,
        _room(const []),
        expectContent: 'Are you sure you want to delete this page? This '
            'action cannot be undone.',
        answer: 'Delete',
        source: StrategySource.local,
      ),
      isTrue,
    );
  });

  testWidgets(
      'with nobody else on the page, asks plainly and says where to restore '
      'it', (tester) async {
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
            'You can restore it from Recently deleted for 30 days.',
        answer: 'Delete anyway',
      ),
      isTrue,
    );
  });

  testWidgets('each name is bold, in its cursor colour on the map',
      (tester) async {
    final room = _room([
      _peer('alex', 'Alex', 'page-1'),
      _peer('sam', 'Sam', 'page-1'),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        strategyPresenceProvider.overrideWith(() => _FixedPresence(room)),
        strategyProvider.overrideWith(() => _Strategy(StrategySource.cloud)),
      ],
      child: ShadApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => Center(
              child: ShadButton(
                onPressed: () => confirmDeletePage(context, ref,
                    pageId: 'page-1', pageName: 'A exec'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final text = tester.widget<Text>(find.textContaining('on this page'));
    final spans = <String, TextStyle?>{};
    text.textSpan!.visitChildren((span) {
      if (span is TextSpan && span.text != null) spans[span.text!] = span.style;
      return true;
    });
    for (final (uid, name) in [('alex', 'Alex'), ('sam', 'Sam')]) {
      expect(spans[name]?.fontWeight, FontWeight.bold);
      expect(spans[name]?.color, presenceColorFor(uid));
    }
    expect(spans[' and ']?.fontWeight, isNull);
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
            'anyway? You can restore it from Recently deleted for 30 days.',
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
          'Delete it anyway? You can restore it from Recently deleted for 30 '
          'days.',
      answer: 'Cancel',
    );
  });
}

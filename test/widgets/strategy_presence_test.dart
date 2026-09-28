import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/strategy_presence_provider.dart';
import 'package:icarus/widgets/strategy_presence.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _FixedPresence extends StrategyPresenceNotifier {
  _FixedPresence(this._state);

  final PresenceRoomState _state;

  @override
  PresenceRoomState build() => _state;
}

PresencePeer _peer(String sid, String uid, String name, String role) =>
    PresencePeer(
      sid: sid,
      uid: uid,
      name: name,
      avatarUrl: null,
      role: role,
      cursor: null,
    );

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
}

import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/presence/presence_models.dart';
import 'package:icarus/collab/presence/presence_room.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  group('applyPresenceMessage', () {
    const empty = PresenceRoomState(connection: PresenceConnection.connecting);

    // Without [editing] this is the peer an old room sends: no editing key.
    Map<String, Object?> peer(
      String sid,
      String uid, {
      Map<String, Object?>? cursor,
      Object? editing,
    }) =>
        {
          'sid': sid,
          'uid': uid,
          'name': 'Name $uid',
          'avatar': null,
          'role': 'editor',
          'cursor': cursor,
          if (editing != null) 'editing': editing,
        };

    test('welcome replaces the room and marks it live', () {
      final state = applyPresenceMessage(empty, {
        't': 'welcome',
        'self': 's-me',
        'uid': 'me',
        'peers': [
          peer('s1', 'ana', cursor: {'page': 'p1', 'x': 10, 'y': 20}),
          {'sid': 'broken'},
        ],
      });
      expect(state.connection, PresenceConnection.live);
      expect(state.selfUid, 'me');
      expect(state.peers.keys, ['s1']);
      expect(
        state.peers['s1']!.cursor,
        const PresenceCursor(pageId: 'p1', x: 10, y: 20),
      );
    });

    test('joins, cursors, hides, and leaves update one peer', () {
      var state = applyPresenceMessage(empty, {
        't': 'welcome',
        'uid': 'me',
        'peers': <Object?>[],
      });
      state =
          applyPresenceMessage(state, {'t': 'join', 'peer': peer('s1', 'ana')});
      state = applyPresenceMessage(
        state,
        {'t': 'cursor', 'sid': 's1', 'page': 'p2', 'x': 1.5, 'y': 2},
      );
      expect(state.cursorsOn('p2').single.sid, 's1');
      expect(state.cursorsOn('p1'), isEmpty);

      // A repeat join (profile refresh) keeps the cursor.
      state =
          applyPresenceMessage(state, {'t': 'join', 'peer': peer('s1', 'ana')});
      expect(state.cursorsOn('p2'), hasLength(1));

      state = applyPresenceMessage(state, {'t': 'hide', 'sid': 's1'});
      expect(state.cursorsOn('p2'), isEmpty);
      state = applyPresenceMessage(state, {'t': 'leave', 'sid': 's1'});
      expect(state.peers, isEmpty);
    });

    test('the page someone is on outlasts their cursor leaving the map', () {
      var state = applyPresenceMessage(empty, {
        't': 'welcome',
        'uid': 'me',
        'peers': [
          peer('s1', 'ana', cursor: {'page': 'p1', 'x': 1, 'y': 1}),
          peer('s2', 'ana', cursor: {'page': 'p2', 'x': 1, 'y': 1}),
          peer('s3', 'ben'),
          peer('s4', 'me', cursor: {'page': 'p1', 'x': 1, 'y': 1}),
        ],
      });
      // Ana is on p1 in one window; Ben's cursor has not shown; you are not
      // someone else.
      expect(state.peopleOn('p1').map((peer) => peer.uid), ['ana']);
      expect(state.peopleOn('p2').map((peer) => peer.uid), ['ana']);

      state = applyPresenceMessage(state, {'t': 'hide', 'sid': 's1'});
      expect(state.cursorsOn('p1'), isEmpty);
      expect(state.peopleOn('p1').map((peer) => peer.uid), ['ana']);
      // A repeat join (profile refresh) keeps it too.
      state =
          applyPresenceMessage(state, {'t': 'join', 'peer': peer('s1', 'ana')});
      expect(state.peopleOn('p1').map((peer) => peer.uid), ['ana']);

      state = applyPresenceMessage(
        state,
        {'t': 'cursor', 'sid': 's1', 'page': 'p3', 'x': 1, 'y': 1},
      );
      state = applyPresenceMessage(state, {'t': 'leave', 'sid': 's2'});
      expect(state.peopleOn('p1'), isEmpty);
      expect(state.peopleOn('p3').map((peer) => peer.uid), ['ana']);
    });

    test('people are one per person and never yourself', () {
      final state = applyPresenceMessage(empty, {
        't': 'welcome',
        'uid': 'me',
        'peers': [
          peer('s1', 'ana'),
          peer('s2', 'ana'),
          peer('s3', 'me', cursor: {'page': 'p1', 'x': 0, 'y': 0}),
          peer('s4', 'ben'),
        ],
      });
      expect(state.people.map((p) => p.uid), ['ana', 'ben']);
      // Your own other window's cursor is not drawn either.
      expect(state.cursorsOn('p1'), isEmpty);
    });

    test('messages about unknown peers change nothing', () {
      final state = applyPresenceMessage(empty, {
        't': 'welcome',
        'uid': 'me',
        'peers': <Object?>[],
      });
      expect(
        identical(
          applyPresenceMessage(
            state,
            {'t': 'cursor', 'sid': 'ghost', 'page': 'p', 'x': 1, 'y': 1},
          ),
          state,
        ),
        isTrue,
      );
      expect(
        identical(
            applyPresenceMessage(state, {'t': 'leave', 'sid': 'x'}), state),
        isTrue,
      );
    });

    test('editing is set, changed, and cleared on one peer', () {
      var state = applyPresenceMessage(empty, {
        't': 'welcome',
        'uid': 'me',
        'peers': [
          peer('s1', 'ana', cursor: {'page': 'p1', 'x': 1, 'y': 2}),
          peer('s2', 'ben'),
        ],
      });
      state = applyPresenceMessage(state, {
        't': 'editing',
        'sid': 's1',
        'page': 'p1',
        'groups': ['g1', 'g2'],
      });
      expect(
        state.peers['s1']!.editing,
        const PresenceEditing(pageId: 'p1', groupIds: {'g2', 'g1'}),
      );
      // Editing leaves the cursor and the other peer alone.
      expect(
        state.peers['s1']!.cursor,
        const PresenceCursor(pageId: 'p1', x: 1, y: 2),
      );
      expect(state.peers['s2']!.editing, isNull);

      state = applyPresenceMessage(state, {
        't': 'editing',
        'sid': 's1',
        'page': 'p2',
        'groups': ['g3'],
      });
      expect(
        state.peers['s1']!.editing,
        const PresenceEditing(pageId: 'p2', groupIds: {'g3'}),
      );

      // The room clears with no page and no groups.
      state = applyPresenceMessage(state, {
        't': 'editing',
        'sid': 's1',
        'page': null,
        'groups': <String>[],
      });
      expect(state.peers['s1']!.editing, isNull);
      expect(state.peers['s1']!.cursor, isNotNull);
    });

    test('editing from an unknown peer changes nothing', () {
      final state = applyPresenceMessage(empty, {
        't': 'welcome',
        'uid': 'me',
        'peers': [peer('s1', 'ana')],
      });
      expect(
        identical(
          applyPresenceMessage(state, {
            't': 'editing',
            'sid': 'ghost',
            'page': 'p1',
            'groups': ['g1'],
          }),
          state,
        ),
        isTrue,
      );
    });

    test('welcome and join peers carry what they are editing', () {
      var state = applyPresenceMessage(empty, {
        't': 'welcome',
        'uid': 'me',
        'peers': [
          peer('s1', 'ana', editing: {
            'page': 'p1',
            'groups': ['g1'],
          }),
        ],
      });
      expect(
        state.peers['s1']!.editing,
        const PresenceEditing(pageId: 'p1', groupIds: {'g1'}),
      );

      state = applyPresenceMessage(state, {
        't': 'join',
        'peer': peer('s2', 'ben', editing: {
          'page': 'p2',
          'groups': ['g2', 'g3'],
        }),
      });
      expect(
        state.peers['s2']!.editing,
        const PresenceEditing(pageId: 'p2', groupIds: {'g2', 'g3'}),
      );
    });

    test('a repeat join keeps what the peer is editing', () {
      var state = applyPresenceMessage(empty, {
        't': 'welcome',
        'uid': 'me',
        'peers': [peer('s1', 'ana')],
      });
      state = applyPresenceMessage(state, {
        't': 'editing',
        'sid': 's1',
        'page': 'p1',
        'groups': ['g1'],
      });
      // A profile refresh, sent without editing.
      state =
          applyPresenceMessage(state, {'t': 'join', 'peer': peer('s1', 'ana')});
      expect(
        state.peers['s1']!.editing,
        const PresenceEditing(pageId: 'p1', groupIds: {'g1'}),
      );
    });

    test('malformed editing reads as nothing', () {
      final malformed = <Object>[
        'p1',
        ['g1'],
        {
          'groups': ['g1']
        },
        {
          'page': 3,
          'groups': ['g1']
        },
        {'page': 'p1'},
        {'page': 'p1', 'groups': 'g1'},
        {'page': 'p1', 'groups': <String>[]},
        {
          'page': 'p1',
          'groups': [1, '', null],
        },
      ];
      for (final editing in malformed) {
        final welcomed = applyPresenceMessage(empty, {
          't': 'welcome',
          'uid': 'me',
          'peers': [peer('s1', 'ana', editing: editing)],
        });
        expect(welcomed.peers['s1'], isNotNull, reason: '$editing');
        expect(welcomed.peers['s1']!.editing, isNull, reason: '$editing');

        if (editing is! Map) continue;
        final edited = applyPresenceMessage(
          applyPresenceMessage(welcomed, {
            't': 'editing',
            'sid': 's1',
            'page': 'p9',
            'groups': ['g9'],
          }),
          {'t': 'editing', 'sid': 's1', ...editing},
        );
        expect(edited.peers['s1']!.editing, isNull, reason: '$editing');
      }

      // Unreadable group ids are dropped; readable ones stay.
      final mixed = applyPresenceMessage(empty, {
        't': 'welcome',
        'uid': 'me',
        'peers': [
          peer('s1', 'ana', editing: {
            'page': 'p1',
            'groups': ['g1', 2, ''],
          }),
        ],
      });
      expect(
        mixed.peers['s1']!.editing,
        const PresenceEditing(pageId: 'p1', groupIds: {'g1'}),
      );
    });

    test('a welcome from a room older than editing still parses', () {
      final state = applyPresenceMessage(empty, {
        't': 'welcome',
        'self': 's-me',
        'uid': 'me',
        'peers': [
          {
            'sid': 's1',
            'uid': 'ana',
            'name': 'Ana',
            'avatar': null,
            'role': 'editor',
            'cursor': {'page': 'p1', 'x': 1, 'y': 2},
          },
          {
            'sid': 's2',
            'uid': 'ben',
            'name': 'Ben',
            'avatar': 'https://example.test/ben.png',
            'role': 'viewer',
            'cursor': null,
          },
        ],
      });
      expect(state.connection, PresenceConnection.live);
      expect(state.peers.keys, ['s1', 's2']);
      expect(state.peers.values.map((peer) => peer.editing), [null, null]);
      expect(state.peopleOn('p1').single.uid, 'ana');
      expect(state.editingLineupGroup('p1', 'g1'), isEmpty);
    });
  });

  group('PresenceRoomState.editingLineupGroup', () {
    PresencePeer editor(
      String sid,
      String uid, {
      String pageId = 'p1',
      Set<String> groups = const {'g1'},
    }) =>
        PresencePeer(
          sid: sid,
          uid: uid,
          name: 'Name $uid',
          avatarUrl: null,
          role: 'editor',
          cursor: null,
          editing: PresenceEditing(pageId: pageId, groupIds: groups),
        );

    test('never names yourself, even from another window', () {
      final state = PresenceRoomState(
        connection: PresenceConnection.live,
        selfUid: 'me',
        peers: {
          's1': editor('s1', 'me'),
          's2': editor('s2', 'ana'),
        },
      );
      expect(state.editingLineupGroup('p1', 'g1').map((peer) => peer.uid),
          ['ana']);
    });

    test('names one person in two windows once', () {
      final state = PresenceRoomState(
        connection: PresenceConnection.live,
        selfUid: 'me',
        peers: {
          's1': editor('s1', 'ana'),
          's2': editor('s2', 'ana', groups: {'g1', 'g2'}),
          's3': editor('s3', 'ben', groups: {'g2'}),
        },
      );
      expect(
          state.editingLineupGroup('p1', 'g1').map((peer) => peer.sid), ['s1']);
      expect(state.editingLineupGroup('p1', 'g2').map((peer) => peer.uid),
          ['ana', 'ben']);
    });

    test('a group on another page does not match', () {
      final state = PresenceRoomState(
        connection: PresenceConnection.live,
        selfUid: 'me',
        peers: {
          's1': editor('s1', 'ana', pageId: 'p2'),
          's2': PresencePeer(
            sid: 's2',
            uid: 'ben',
            name: 'Ben',
            avatarUrl: null,
            role: 'editor',
            cursor: const PresenceCursor(pageId: 'p1', x: 0, y: 0),
          ),
        },
      );
      expect(state.editingLineupGroup('p1', 'g1'), isEmpty);
      expect(state.editingLineupGroup('p2', 'g1').single.uid, 'ana');
      expect(state.editingLineupGroup('p2', 'g2'), isEmpty);
    });
  });

  group('PresenceRoom', () {
    late List<_FakeSocket> sockets;
    late int passesIssued;

    RoomPass pass() {
      passesIssued++;
      return RoomPass(
        url: Uri.parse('wss://presence.test/v1/rooms/strat'),
        pass: 'pass-$passesIssued',
        expiresAt: DateTime.now().add(const Duration(minutes: 2)),
      );
    }

    PresenceRoom room({Future<RoomPass?> Function()? issuePass}) {
      return PresenceRoom(
        issuePass: issuePass ?? () async => pass(),
        connect: (uri) {
          final socket = _FakeSocket(uri);
          sockets.add(socket);
          return socket;
        },
      );
    }

    setUp(() {
      sockets = [];
      passesIssued = 0;
    });

    void welcome(FakeAsync async, _FakeSocket socket) {
      socket
          .receive({'t': 'welcome', 'self': 's-me', 'uid': 'me', 'peers': []});
      async.flushMicrotasks();
    }

    test('joins with the pass in the query and goes live on welcome', () {
      fakeAsync((async) {
        final presence = room()..start();
        async.flushMicrotasks();
        expect(presence.state.connection, PresenceConnection.connecting);
        expect(sockets.single.uri.queryParameters['pass'], 'pass-1');
        welcome(async, sockets.single);
        expect(presence.state.connection, PresenceConnection.live);
        presence.dispose();
      });
    });

    test('is off when the deployment has no presence service', () {
      fakeAsync((async) {
        final presence = room(issuePass: () async => null)..start();
        async.flushMicrotasks();
        expect(presence.state.connection, PresenceConnection.off);
        expect(sockets, isEmpty);
        presence.dispose();
      });
    });

    test('sends at most one cursor per interval, and always the last', () {
      fakeAsync((async) {
        final presence = room()..start();
        async.flushMicrotasks();
        welcome(async, sockets.single);
        for (var x = 0; x < 5; x++) {
          presence
              .moveCursor(PresenceCursor(pageId: 'p1', x: x.toDouble(), y: 0));
          async.elapse(const Duration(milliseconds: 5));
        }
        expect(sockets.single.sentCursors, [0.0]);
        async.elapse(const Duration(milliseconds: 50));
        expect(sockets.single.sentCursors, [0.0, 4.0]);

        presence.hideCursor();
        expect(sockets.single.sent.last, {'t': 'hide'});
        // Nothing to hide twice.
        presence.hideCursor();
        expect(sockets.single.sent.where((m) => m is Map && m['t'] == 'hide'),
            hasLength(1));
        presence.dispose();
      });
    });

    test('rejoins after a drop and sends the cursor again', () {
      fakeAsync((async) {
        final presence = room()..start();
        async.flushMicrotasks();
        welcome(async, sockets.first);
        presence.moveCursor(const PresenceCursor(pageId: 'p1', x: 7, y: 8));
        expect(sockets.first.sentCursors, [7.0]);

        sockets.first.drop(1006);
        async.flushMicrotasks();
        expect(presence.state.connection, PresenceConnection.connecting);
        expect(presence.state.peers, isEmpty);

        async.elapse(const Duration(seconds: 1));
        expect(sockets, hasLength(2));
        expect(sockets.last.uri.queryParameters['pass'], 'pass-2');
        welcome(async, sockets.last);
        async.flushMicrotasks();
        expect(presence.state.connection, PresenceConnection.live);
        expect(sockets.last.sentCursors, [7.0]);
        presence.dispose();
      });
    });

    test('backs off while passes cannot be issued', () {
      fakeAsync((async) {
        var failing = true;
        final presence = room(issuePass: () async {
          if (failing) throw StateError('offline');
          return pass();
        })
          ..start();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1)); // retry 1 fails
        async.elapse(const Duration(seconds: 2)); // retry 2 fails
        expect(sockets, isEmpty);
        failing = false;
        async.elapse(const Duration(seconds: 4));
        expect(sockets, hasLength(1));
        presence.dispose();
      });
    });

    test('renews the pass halfway through its life', () {
      fakeAsync((async) {
        final presence = room()..start();
        async.flushMicrotasks();
        welcome(async, sockets.single);
        for (var second = 0; second < 61; second++) {
          async.elapse(const Duration(seconds: 1));
          sockets.single.pong();
          async.flushMicrotasks();
        }
        expect(
          sockets.single.sent,
          anyElement(equals({'t': 'renew', 'pass': 'pass-2'})),
        );
        presence.dispose();
      });
    });

    test('an idle connection that stops answering is replaced', () {
      fakeAsync((async) {
        final presence = room()..start();
        async.flushMicrotasks();
        welcome(async, sockets.single);
        // Pings go out; no pong ever comes back.
        async.elapse(const Duration(seconds: 61));
        expect(sockets.first.sent, contains('ping'));
        expect(sockets.first.closed, isTrue);
        async.elapse(const Duration(seconds: 1));
        expect(sockets, hasLength(2));
        presence.dispose();
      });
    });

    PresenceEditing editing(String pageId, Set<String> groups) =>
        PresenceEditing(pageId: pageId, groupIds: groups);
    const interval = Duration(milliseconds: 150);

    test('sends what this user edits, sorted, and at most eight groups', () {
      fakeAsync((async) {
        final presence = room()..start();
        async.flushMicrotasks();
        welcome(async, sockets.single);
        expect(presence.editingInterval, interval);

        presence.setEditing(editing('p1', {'g2', 'g1'}));
        expect(sockets.single.sent.last, {
          't': 'editing',
          'page': 'p1',
          'groups': ['g1', 'g2'],
        });

        // The room ignores a message naming more than eight.
        async.elapse(interval);
        presence.setEditing(editing('p1', {
          for (var i = 9; i >= 0; i--) 'g$i',
        }));
        expect(sockets.single.sent.last, {
          't': 'editing',
          'page': 'p1',
          'groups': ['g0', 'g1', 'g2', 'g3', 'g4', 'g5', 'g6', 'g7'],
        });
        expect(sockets.single.sentEditing, hasLength(2));
        presence.dispose();
      });
    });

    test('sends at most one editing per interval, and always the last', () {
      fakeAsync((async) {
        final presence = room()..start();
        async.flushMicrotasks();
        welcome(async, sockets.single);

        presence.setEditing(editing('p1', {'g1'}));
        async.elapse(const Duration(milliseconds: 10));
        presence.setEditing(editing('p1', {'g2'}));
        async.elapse(const Duration(milliseconds: 10));
        presence.setEditing(editing('p2', {'g3'}));
        expect(sockets.single.sentEditing, hasLength(1));

        async.elapse(const Duration(milliseconds: 129));
        expect(sockets.single.sentEditing, hasLength(1));
        async.elapse(const Duration(milliseconds: 1));
        expect(sockets.single.sentEditing.last, {
          't': 'editing',
          'page': 'p2',
          'groups': ['g3'],
        });
        final at = sockets.single.sentEditingAt;
        expect(at[1].difference(at[0]), interval);

        async.elapse(const Duration(seconds: 1));
        expect(sockets.single.sentEditing, hasLength(2));

        // There and back within the interval: the room already has it.
        presence.setEditing(editing('p2', {'g4'}));
        expect(sockets.single.sentEditing, hasLength(3));
        presence.setEditing(editing('p2', {'g5'}));
        presence.setEditing(editing('p2', {'g4'}));
        async.elapse(const Duration(seconds: 1));
        expect(sockets.single.sentEditing, hasLength(3));
        presence.dispose();
      });
    });

    test('clearing sends no groups for the page it last sent', () {
      fakeAsync((async) {
        final presence = room()..start();
        async.flushMicrotasks();
        welcome(async, sockets.single);

        presence.setEditing(editing('p1', {'g1'}));
        async.elapse(interval);
        presence.setEditing(editing('p2', {'g2'}));
        async.elapse(interval);
        presence.setEditing(null);
        expect(sockets.single.sent.last, {
          't': 'editing',
          'page': 'p2',
          'groups': <String>[],
        });

        // A clear that waits out the interval still names the page.
        async.elapse(interval);
        presence.setEditing(editing('p3', {'g3'}));
        presence.setEditing(null);
        async.elapse(interval);
        expect(sockets.single.sentEditing, hasLength(5));
        expect(sockets.single.sent.last, {
          't': 'editing',
          'page': 'p3',
          'groups': <String>[],
        });

        // Something that never went out needs no clear.
        presence.setEditing(editing('p4', {'g4'}));
        presence.setEditing(null);
        async.elapse(const Duration(seconds: 1));
        expect(sockets.single.sentEditing, hasLength(5));
        presence.dispose();
      });
    });

    test('sends nothing when what this user edits is unchanged', () {
      fakeAsync((async) {
        final presence = room()..start();
        async.flushMicrotasks();
        welcome(async, sockets.single);

        // Nothing edited, nothing to clear.
        presence.setEditing(null);
        async.elapse(interval);
        expect(sockets.single.sentEditing, isEmpty);

        presence.setEditing(editing('p1', {'g1', 'g2'}));
        async.elapse(interval);
        presence.setEditing(editing('p1', {'g2', 'g1'}));
        async.elapse(const Duration(seconds: 1));
        expect(sockets.single.sentEditing, hasLength(1));

        presence.setEditing(null);
        async.elapse(interval);
        presence.setEditing(null);
        async.elapse(const Duration(seconds: 1));
        expect(sockets.single.sentEditing, hasLength(2));
        presence.dispose();
      });
    });

    test('rejoins after a drop and sends what this user edits again', () {
      fakeAsync((async) {
        final presence = room()..start();
        async.flushMicrotasks();
        welcome(async, sockets.first);
        presence.setEditing(editing('p1', {'g1'}));
        expect(sockets.first.sentEditing, hasLength(1));

        sockets.first.drop(1006);
        async.flushMicrotasks();
        // Changed while away: only the latest goes out after the rejoin.
        presence.setEditing(editing('p1', {'g2'}));
        async.elapse(interval);
        expect(sockets.first.sentEditing, hasLength(1));

        async.elapse(const Duration(seconds: 1));
        expect(sockets, hasLength(2));
        expect(sockets.last.sentEditing, isEmpty);
        welcome(async, sockets.last);
        expect(sockets.last.sentEditing, [
          {
            't': 'editing',
            'page': 'p1',
            'groups': ['g2'],
          },
        ]);
        async.elapse(const Duration(seconds: 1));
        expect(sockets.last.sentEditing, hasLength(1));

        // Stopped while away: the new room never heard of it, so nothing
        // goes out.
        sockets.last.drop(1006);
        async.flushMicrotasks();
        presence.setEditing(null);
        async.elapse(const Duration(seconds: 2));
        expect(sockets, hasLength(3));
        welcome(async, sockets.last);
        async.elapse(const Duration(seconds: 1));
        expect(sockets.last.sentEditing, isEmpty);
        presence.dispose();
      });
    });

    test('a quick rejoin keeps editing messages an interval apart', () {
      fakeAsync((async) {
        final presence = room()..start();
        async.flushMicrotasks();
        welcome(async, sockets.first);
        // Long enough that a lapsed pass rejoins at once.
        async.elapse(const Duration(seconds: 11));

        presence.setEditing(editing('p1', {'g1'}));
        async.elapse(const Duration(milliseconds: 10));
        // Waits for the interval.
        presence.setEditing(editing('p1', {'g2'}));
        sockets.first.drop(closePassExpired);
        async.flushMicrotasks();
        expect(sockets, hasLength(2));

        async.elapse(const Duration(milliseconds: 90));
        welcome(async, sockets.last); // resends g2
        async.elapse(const Duration(milliseconds: 10));
        presence.setEditing(editing('p1', {'g3'}));
        async.elapse(const Duration(seconds: 1));

        expect(sockets.last.sentEditing.last['groups'], ['g3']);
        // The room drops an editing message sent within 100 ms of the last,
        // so the last state would never reach it.
        final at = sockets.last.sentEditingAt;
        for (var i = 1; i < at.length; i++) {
          expect(
            at[i].difference(at[i - 1]),
            greaterThanOrEqualTo(presence.editingInterval),
            reason: 'editing message $i of ${sockets.last.sentEditing}',
          );
        }
        presence.dispose();
      });
    });
  });
}

class _FakeSocket extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  _FakeSocket(this.uri);

  final Uri uri;
  final _incoming = StreamController<dynamic>();
  final List<Object?> sent = [];

  /// When each of [sent] went out, by the (fake) clock.
  final List<DateTime> sentAt = [];
  bool closed = false;
  int? _closeCode;

  List<double> get sentCursors => [
        for (final message in sent)
          if (message is Map && message['t'] == 'cursor')
            (message['x'] as num).toDouble(),
      ];

  List<Map<dynamic, dynamic>> get sentEditing => [
        for (final message in sent)
          if (message is Map && message['t'] == 'editing') message,
      ];

  /// When each of [sentEditing] went out.
  List<DateTime> get sentEditingAt => [
        for (final (index, message) in sent.indexed)
          if (message is Map && message['t'] == 'editing') sentAt[index],
      ];

  void receive(Map<String, Object?> message) =>
      _incoming.add(jsonEncode(message));

  void pong() => _incoming.add('pong');

  void drop(int code) {
    _closeCode = code;
    _incoming.close();
  }

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  late final WebSocketSink sink = _FakeSink(this);

  @override
  Future<void> get ready => Future.value();

  @override
  int? get closeCode => _closeCode;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this._socket);

  final _FakeSocket _socket;

  @override
  void add(dynamic data) {
    final text = data as String;
    _socket.sent.add(text == 'ping' ? text : jsonDecode(text));
    _socket.sentAt.add(clock.now());
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    _socket.closed = true;
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) => stream.forEach(add);

  @override
  Future<void> get done => Future.value();
}

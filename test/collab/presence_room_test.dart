import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/presence/presence_models.dart';
import 'package:icarus/collab/presence/presence_room.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  group('applyPresenceMessage', () {
    const empty = PresenceRoomState(connection: PresenceConnection.connecting);

    Map<String, Object?> peer(
      String sid,
      String uid, {
      Map<String, Object?>? cursor,
    }) =>
        {
          'sid': sid,
          'uid': uid,
          'name': 'Name $uid',
          'avatar': null,
          'role': 'editor',
          'cursor': cursor,
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
  });
}

class _FakeSocket extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  _FakeSocket(this.uri);

  final Uri uri;
  final _incoming = StreamController<dynamic>();
  final List<Object?> sent = [];
  bool closed = false;
  int? _closeCode;

  List<double> get sentCursors => [
        for (final message in sent)
          if (message is Map && message['t'] == 'cursor')
            (message['x'] as num).toDouble(),
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

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:icarus/collab/presence/presence_models.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Asks Convex for a pass. Null means this deployment has no presence
/// service; a throw means the request failed (offline, access revoked).
typedef RoomPassIssuer = Future<RoomPass?> Function();
typedef RoomSocketConnector = WebSocketChannel Function(Uri uri);

/// Sent by the room when a pass runs out or a renewal is refused.
const int closePassExpired = 4001;

/// One live connection to a strategy's presence room.
///
/// It keeps itself connected: it rejoins with a fresh pass after any drop,
/// renews the pass before it runs out, and pings so a dead connection is
/// noticed. Cursor moves are throttled to [cursorInterval] and only the
/// latest position is ever sent; nothing is queued across a disconnect.
class PresenceRoom {
  PresenceRoom({
    required RoomPassIssuer issuePass,
    RoomSocketConnector? connect,
    this.cursorInterval = const Duration(milliseconds: 50),
    this.keepAliveInterval = const Duration(seconds: 20),
    this.silenceLimit = const Duration(seconds: 50),
    this.maxRetryDelay = const Duration(seconds: 30),
  })  : _issuePass = issuePass,
        _connect = connect ?? WebSocketChannel.connect;

  final RoomPassIssuer _issuePass;
  final RoomSocketConnector _connect;
  final Duration cursorInterval;
  final Duration keepAliveInterval;
  final Duration silenceLimit;
  final Duration maxRetryDelay;

  final _states = StreamController<PresenceRoomState>.broadcast(sync: true);
  PresenceRoomState _state =
      const PresenceRoomState(connection: PresenceConnection.connecting);

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _retryTimer;
  Timer? _renewTimer;
  Timer? _keepAliveTimer;
  Timer? _cursorTimer;
  int _failures = 0;
  DateTime _lastHeard = clock.now();
  DateTime _joinedAt = clock.now();
  bool _disposed = false;

  /// Increments on every (re)connect so late callbacks from an old socket
  /// can tell they are stale.
  int _generation = 0;

  /// Where the pointer is now, whether or not it has gone out yet.
  PresenceCursor? _currentCursor;
  PresenceCursor? _pendingCursor;
  PresenceCursor? _sentCursor;
  DateTime? _lastCursorSentAt;

  PresenceRoomState get state => _state;
  Stream<PresenceRoomState> get states => _states.stream;

  void start() => unawaited(_join());

  /// Where this user's cursor is now. Throttled; the last position always
  /// goes out.
  void moveCursor(PresenceCursor cursor) {
    _currentCursor = cursor;
    _pendingCursor = cursor;
    if (_cursorTimer != null) return;
    final lastSent = _lastCursorSentAt;
    final wait = lastSent == null
        ? Duration.zero
        : cursorInterval - clock.now().difference(lastSent);
    if (wait <= Duration.zero) {
      _flushCursor();
    } else {
      _cursorTimer = Timer(wait, _flushCursor);
    }
  }

  /// The pointer left the map.
  void hideCursor() {
    _cursorTimer?.cancel();
    _cursorTimer = null;
    _pendingCursor = null;
    _currentCursor = null;
    if (_sentCursor == null) return;
    _sentCursor = null;
    _send({'t': 'hide'});
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _closeSocket();
    _retryTimer?.cancel();
    _cursorTimer?.cancel();
    unawaited(_states.close());
  }

  void _flushCursor() {
    _cursorTimer = null;
    final cursor = _pendingCursor;
    _pendingCursor = null;
    if (cursor == null || cursor == _sentCursor) return;
    if (_send({
      't': 'cursor',
      'page': cursor.pageId,
      'x': _round(cursor.x),
      'y': _round(cursor.y),
    })) {
      _sentCursor = cursor;
      _lastCursorSentAt = clock.now();
    }
  }

  Future<void> _join() async {
    final generation = ++_generation;
    RoomPass? pass;
    try {
      pass = await _issuePass();
    } catch (_) {
      if (generation == _generation && !_disposed) _retryLater();
      return;
    }
    if (generation != _generation || _disposed) return;
    if (pass == null) {
      _emit(PresenceRoomState.off);
      return;
    }

    final WebSocketChannel channel;
    try {
      channel = _connect(
        pass.url.replace(queryParameters: {'pass': pass.pass}),
      );
      await channel.ready;
    } catch (_) {
      if (generation == _generation && !_disposed) _retryLater();
      return;
    }
    if (generation != _generation || _disposed) {
      unawaited(channel.sink.close());
      return;
    }

    _channel = channel;
    _joinedAt = _lastHeard = clock.now();
    _subscription = channel.stream.listen(
      (message) => _onMessage(generation, message),
      onDone: () => _onDropped(generation),
      onError: (Object _) => _onDropped(generation),
      cancelOnError: true,
    );
    _scheduleRenewal(generation, pass.expiresAt);
    _keepAliveTimer = Timer.periodic(keepAliveInterval, (_) {
      if (clock.now().difference(_lastHeard) > silenceLimit) {
        _onDropped(generation);
      } else {
        _send('ping');
      }
    });
  }

  void _onMessage(int generation, dynamic raw) {
    if (generation != _generation) return;
    _lastHeard = clock.now();
    if (raw is! String || raw == 'pong') return;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    final next = applyPresenceMessage(_state, decoded);
    if (decoded['t'] == 'welcome') {
      _failures = 0;
      // After a rejoin the room has forgotten this cursor; send it again.
      final cursor = _currentCursor;
      if (cursor != null) moveCursor(cursor);
    }
    if (!identical(next, _state)) _emit(next);
  }

  void _onDropped(int generation) {
    if (generation != _generation || _disposed) return;
    // A pass that ran out after a healthy stretch (say, the laptop slept
    // through its renewal) is not a failure: rejoin with a fresh one now.
    // Anything quicker backs off, so a bad clock can't spin.
    final expired = _channel?.closeCode == closePassExpired &&
        clock.now().difference(_joinedAt) > const Duration(seconds: 10);
    _closeSocket();
    if (expired) {
      unawaited(_join());
    } else {
      _retryLater();
    }
  }

  void _retryLater() {
    _closeSocket();
    _emit(const PresenceRoomState(connection: PresenceConnection.connecting));
    final seconds = math.min(
      maxRetryDelay.inSeconds,
      math.pow(2, _failures).toInt(),
    );
    _failures++;
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(seconds: seconds), () => unawaited(_join()));
  }

  void _scheduleRenewal(int generation, DateTime expiresAt) {
    // Halfway through the pass's life. The expiry is the server's clock, so
    // clamp it: a skewed local clock must neither spin nor let it lapse.
    final halfLife = expiresAt.difference(clock.now()) ~/ 2;
    final renewIn = halfLife < const Duration(seconds: 20)
        ? const Duration(seconds: 20)
        : halfLife > const Duration(seconds: 60)
            ? const Duration(seconds: 60)
            : halfLife;
    _renewTimer?.cancel();
    _renewTimer = Timer(renewIn, () async {
      RoomPass? pass;
      try {
        pass = await _issuePass();
      } catch (_) {
        // Offline or access revoked. The room closes the socket when the
        // current pass runs out; rejoining then decides which it was.
        return;
      }
      if (generation != _generation || pass == null) return;
      if (_send({'t': 'renew', 'pass': pass.pass})) {
        _scheduleRenewal(generation, pass.expiresAt);
      }
    });
  }

  bool _send(Object message) {
    final channel = _channel;
    if (channel == null) return false;
    try {
      channel.sink.add(message is String ? message : jsonEncode(message));
      return true;
    } catch (_) {
      return false;
    }
  }

  void _closeSocket() {
    _renewTimer?.cancel();
    _keepAliveTimer?.cancel();
    _renewTimer = null;
    _keepAliveTimer = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) unawaited(channel.sink.close());
    _sentCursor = null;
  }

  void _emit(PresenceRoomState next) {
    if (_disposed) return;
    _state = next;
    _states.add(next);
  }
}

/// The room state after one server message. Pure, so it is tested alone.
PresenceRoomState applyPresenceMessage(
  PresenceRoomState state,
  Map<String, dynamic> message,
) {
  switch (message['t']) {
    case 'welcome':
      final peers = <String, PresencePeer>{};
      for (final raw in (message['peers'] as List? ?? const [])) {
        final peer = _peerFrom(raw);
        if (peer != null) peers[peer.sid] = peer;
      }
      return PresenceRoomState(
        connection: PresenceConnection.live,
        selfUid: message['uid'] as String?,
        peers: peers,
      );
    case 'join':
      final peer = _peerFrom(message['peer']);
      if (peer == null) return state;
      // A repeat join is a profile refresh; keep the cursor and page we
      // already have.
      final existing = state.peers[peer.sid];
      return state.copyWith(peers: {
        ...state.peers,
        peer.sid: existing == null ? peer : peer.at(existing),
      });
    case 'leave':
      final sid = message['sid'];
      if (!state.peers.containsKey(sid)) return state;
      return state.copyWith(peers: {...state.peers}..remove(sid));
    case 'cursor':
      final peer = state.peers[message['sid']];
      final cursor = _cursorFrom(message);
      if (peer == null || cursor == null) return state;
      return state.copyWith(
        peers: {...state.peers, peer.sid: peer.withCursor(cursor)},
      );
    case 'hide':
      final peer = state.peers[message['sid']];
      if (peer == null || peer.cursor == null) return state;
      return state.copyWith(
        peers: {...state.peers, peer.sid: peer.withCursor(null)},
      );
    default:
      return state;
  }
}

PresencePeer? _peerFrom(Object? raw) {
  if (raw is! Map) return null;
  final sid = raw['sid'];
  final uid = raw['uid'];
  final name = raw['name'];
  final role = raw['role'];
  if (sid is! String || uid is! String || name is! String || role is! String) {
    return null;
  }
  final avatar = raw['avatar'];
  final cursor = raw['cursor'];
  return PresencePeer(
    sid: sid,
    uid: uid,
    name: name,
    avatarUrl: avatar is String && avatar.isNotEmpty ? avatar : null,
    role: role,
    cursor: cursor is Map ? _cursorFrom(cursor) : null,
  );
}

PresenceCursor? _cursorFrom(Map<dynamic, dynamic> raw) {
  final page = raw['page'];
  final x = raw['x'];
  final y = raw['y'];
  if (page is! String || x is! num || y is! num) return null;
  return PresenceCursor(pageId: page, x: x.toDouble(), y: y.toDouble());
}

/// A tenth of a world unit is far below a pixel; shorter messages.
double _round(double value) => (value * 10).roundToDouble() / 10;

/// Who else has a cloud strategy open, and where their cursor is.
///
/// Presence is never saved and never queued. It lives in the icarus-presence
/// Worker (presence/) for as long as someone is connected; Convex only signs
/// the pass that lets them in (convex/presence.ts).
library;

/// Convex's permission to join one strategy's room until [expiresAt].
class RoomPass {
  const RoomPass({
    required this.url,
    required this.pass,
    required this.expiresAt,
  });

  final Uri url;
  final String pass;
  final DateTime expiresAt;
}

/// A cursor in canonical (attack-side) world coordinates on one page, so every
/// viewer can place it whatever their zoom, window size, or side.
class PresenceCursor {
  const PresenceCursor({
    required this.pageId,
    required this.x,
    required this.y,
  });

  final String pageId;
  final double x;
  final double y;

  @override
  bool operator ==(Object other) =>
      other is PresenceCursor &&
      other.pageId == pageId &&
      other.x == x &&
      other.y == y;

  @override
  int get hashCode => Object.hash(pageId, x, y);
}

/// One connection to the room. The same person in two windows is two peers
/// with one [uid].
class PresencePeer {
  const PresencePeer({
    required this.sid,
    required this.uid,
    required this.name,
    required this.avatarUrl,
    required this.role,
    required this.cursor,
  });

  final String sid;
  final String uid;
  final String name;
  final String? avatarUrl;

  /// owner, editor, or viewer.
  final String role;
  final PresenceCursor? cursor;

  PresencePeer withCursor(PresenceCursor? cursor) => PresencePeer(
        sid: sid,
        uid: uid,
        name: name,
        avatarUrl: avatarUrl,
        role: role,
        cursor: cursor,
      );
}

enum PresenceConnection {
  /// Not a cloud strategy, or this deployment has no presence service.
  off,

  /// Joining for the first time, or rejoining after the connection dropped.
  connecting,
  live,
}

class PresenceRoomState {
  const PresenceRoomState({
    required this.connection,
    this.selfUid,
    this.peers = const <String, PresencePeer>{},
  });

  static const off = PresenceRoomState(connection: PresenceConnection.off);

  final PresenceConnection connection;
  final String? selfUid;

  /// By session id; never includes this connection.
  final Map<String, PresencePeer> peers;

  /// Everyone else here, one entry per person, in the order they arrived.
  /// Your own other windows are not "someone else".
  List<PresencePeer> get people {
    final seen = <String>{};
    return [
      for (final peer in peers.values)
        if (peer.uid != selfUid && seen.add(peer.uid)) peer,
    ];
  }

  /// Other people's cursors on [pageId].
  List<PresencePeer> cursorsOn(String pageId) => [
        for (final peer in peers.values)
          if (peer.uid != selfUid && peer.cursor?.pageId == pageId) peer,
      ];

  PresenceRoomState copyWith({
    PresenceConnection? connection,
    String? selfUid,
    Map<String, PresencePeer>? peers,
  }) {
    return PresenceRoomState(
      connection: connection ?? this.connection,
      selfUid: selfUid ?? this.selfUid,
      peers: peers ?? this.peers,
    );
  }
}

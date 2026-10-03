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

/// The lineup groups one connection is editing, on one page: the groups of
/// the lineups and spots it holds, places from, or has open. Edits to one
/// group at the same time conflict, so teammates see it before they start.
class PresenceEditing {
  const PresenceEditing({required this.pageId, required this.groupIds});

  final String pageId;
  final Set<String> groupIds;

  @override
  bool operator ==(Object other) =>
      other is PresenceEditing &&
      other.pageId == pageId &&
      other.groupIds.length == groupIds.length &&
      other.groupIds.containsAll(groupIds);

  @override
  int get hashCode => Object.hash(pageId, Object.hashAllUnordered(groupIds));
}

/// One connection to the room. The same person in two windows is two peers
/// with one [uid].
class PresencePeer {
  PresencePeer({
    required this.sid,
    required this.uid,
    required this.name,
    required this.avatarUrl,
    required this.role,
    required this.cursor,
    String? pageId,
    this.editing,
  }) : pageId = pageId ?? cursor?.pageId;

  final String sid;
  final String uid;
  final String name;
  final String? avatarUrl;

  /// owner, editor, or viewer.
  final String role;
  final PresenceCursor? cursor;

  /// The page their cursor was last on. It stays when the pointer leaves
  /// the map, since they are most likely still on that page; unknown until
  /// their cursor first shows.
  final String? pageId;

  /// The lineup groups they are editing, if any.
  final PresenceEditing? editing;

  /// With [cursor] in place of the last one; hiding it keeps [pageId].
  PresencePeer withCursor(PresenceCursor? cursor) => PresencePeer(
        sid: sid,
        uid: uid,
        name: name,
        avatarUrl: avatarUrl,
        role: role,
        cursor: cursor,
        pageId: cursor?.pageId ?? pageId,
        editing: editing,
      );

  /// With [editing] in place of what they were editing.
  PresencePeer withEditing(PresenceEditing? editing) => PresencePeer(
        sid: sid,
        uid: uid,
        name: name,
        avatarUrl: avatarUrl,
        role: role,
        cursor: cursor,
        pageId: pageId,
        editing: editing,
      );

  /// This profile, where [earlier] was: its cursor and its page.
  PresencePeer at(PresencePeer earlier) => PresencePeer(
        sid: sid,
        uid: uid,
        name: name,
        avatarUrl: avatarUrl,
        role: role,
        cursor: earlier.cursor,
        pageId: earlier.pageId,
        editing: editing ?? earlier.editing,
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

  /// Everyone else last seen on [pageId], one entry per person. Presence is
  /// best-effort: someone whose cursor has not shown yet is not counted.
  List<PresencePeer> peopleOn(String pageId) {
    final seen = <String>{};
    return [
      for (final peer in peers.values)
        if (peer.uid != selfUid && peer.pageId == pageId && seen.add(peer.uid))
          peer,
    ];
  }

  /// Everyone else editing lineup group [groupId] on [pageId], one entry
  /// per person.
  List<PresencePeer> editingLineupGroup(String pageId, String groupId) {
    final seen = <String>{};
    return [
      for (final peer in peers.values)
        if (peer.uid != selfUid &&
            peer.editing?.pageId == pageId &&
            (peer.editing?.groupIds.contains(groupId) ?? false) &&
            seen.add(peer.uid))
          peer,
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

import 'dart:math' as math;

import 'package:icarus/collab/collab_models.dart';

/// Page changes are what a user does to a cloud strategy's list of pages:
/// add a page, rename one, delete one, move one. They wait in the outbox as
/// one ordered list per strategy (EntitySyncKey.pageChange records, each
/// with its place in the list), so two changes to the same page never
/// replace each other and a restart keeps them in the order they were made.
///
/// A page's side is not a page change: the canvas syncs it with the page's
/// other content (EntitySyncKey.pageDescriptor).

/// Whether [op] belongs in a strategy's list of page changes.
bool isPageChangeOp(StrategyOp op) => switch (op) {
      PageAddOp() || PageDeleteOp() || PageReorderOp() => true,
      PagePatchOp(:final payload) => payload.containsKey('name'),
      _ => false,
    };

/// Whether [op] renumbers the strategy's pages: an add, delete or reorder.
/// The server checks these against the strategy's revision, and rewrites
/// the place (and an automatic name) of every page that moves, which moves
/// that page's revision on too.
bool renumbersPages(StrategyOp op) =>
    op is PageAddOp || op is PageDeleteOp || op is PageReorderOp;

/// A page as this device draws it: the server's, with this device's page
/// changes that the server has not shown yet on top.
class DrawnPage {
  const DrawnPage({
    required this.publicId,
    required this.name,
    required this.isAutoNamed,
    required this.isAttack,
    required this.revision,
    this.madeHere = false,
  });

  final String publicId;
  final String name;
  final bool isAutoNamed;
  final bool isAttack;

  /// The page's revision on the server as last read; null for a page whose
  /// add has not landed (the server makes it at revision 1).
  final int? revision;

  /// Whether this device added the page with nothing for the server to
  /// copy onto it (see page_made_here.dart), and the add has not landed:
  /// everything on it is in this device's queue.
  final bool madeHere;

  /// Whether the page can open on the canvas: it is on the server, so a
  /// read of it exists, or it was [madeHere], so the queue holds all of
  /// it. A page the server is still to copy has nothing to open yet.
  bool get opens => revision != null || madeHere;

  DrawnPage copyWith({String? name, bool? isAutoNamed, bool? isAttack}) =>
      DrawnPage(
        publicId: publicId,
        name: name ?? this.name,
        isAutoNamed: isAutoNamed ?? this.isAutoNamed,
        isAttack: isAttack ?? this.isAttack,
        revision: revision,
        madeHere: madeHere,
      );

  @override
  bool operator ==(Object other) =>
      other is DrawnPage &&
      other.publicId == publicId &&
      other.name == name &&
      other.isAutoNamed == isAutoNamed &&
      other.isAttack == isAttack &&
      other.revision == revision &&
      other.madeHere == madeHere;

  @override
  int get hashCode =>
      Object.hash(publicId, name, isAutoNamed, isAttack, revision, madeHere);
}

/// [serverPages] in order, with [changes] applied the way the server
/// applies them (convex/ops.ts applyPageOp), in the order given. Changes
/// the server would refuse or find nothing to do for (a page already gone,
/// or added twice) change nothing here either. A page in [pageRevisions]
/// is drawn at that revision when it is newer than the read's: this
/// device's own change moved it there.
List<DrawnPage> drawPages(
  Iterable<RemotePage> serverPages,
  Iterable<StrategyOp> changes, {
  Map<String, int> pageRevisions = const {},
}) {
  final ordered = [...serverPages]
    ..sort((left, right) => left.sortIndex.compareTo(right.sortIndex));
  final pages = [
    for (final page in ordered)
      DrawnPage(
        publicId: page.publicId,
        name: page.name,
        isAutoNamed: page.isAutoNamed == true,
        isAttack: page.isAttack,
        revision: math.max(page.revision, pageRevisions[page.publicId] ?? 0),
      ),
  ];
  int indexOf(String pageId) =>
      pages.indexWhere((page) => page.publicId == pageId);
  // An add, delete or reorder renames every automatically named page after
  // its new place.
  void renumber() {
    for (var i = 0; i < pages.length; i++) {
      if (pages[i].isAutoNamed) {
        pages[i] = pages[i].copyWith(name: 'Page ${i + 1}');
      }
    }
  }

  for (final change in changes) {
    switch (change) {
      case PageAddOp(
          :final pagePublicId,
          :final payload,
          :final sortIndex,
          :final copyContentFromPagePublicId,
        ):
        if (indexOf(pagePublicId) >= 0) continue;
        pages.insert(
          sortIndex.clamp(0, pages.length),
          DrawnPage(
            publicId: pagePublicId,
            name: payload['name'] as String? ?? 'Page',
            isAutoNamed: payload['isAutoNamed'] == true,
            isAttack: payload['isAttack'] as bool? ?? true,
            revision: null,
            madeHere: copyContentFromPagePublicId == null,
          ),
        );
        renumber();
      case PageDeleteOp(:final pagePublicId):
        final index = indexOf(pagePublicId);
        // The server never deletes the last page.
        if (index < 0 || pages.length <= 1) continue;
        pages.removeAt(index);
        renumber();
      case PageReorderOp(:final pagePublicId, :final sortIndex):
        final index = indexOf(pagePublicId);
        if (index < 0) continue;
        final moved = pages.removeAt(index);
        pages.insert(sortIndex.clamp(0, pages.length), moved);
        renumber();
      case PagePatchOp(:final pagePublicId, :final payload):
        final index = indexOf(pagePublicId);
        if (index < 0) continue;
        pages[index] = pages[index].copyWith(
          name: payload['name'] as String?,
          isAutoNamed: payload['isAutoNamed'] as bool?,
          isAttack: payload['isAttack'] as bool?,
        );
      default:
        continue;
    }
  }
  return pages;
}

/// A page as this device last saw it, kept with its delete: before a delete
/// made offline goes, a fresh read of the page is compared with this, so a
/// teammate's work on the page made meanwhile is never trashed unasked.
///
/// The page's place is not part of it: the delete is checked against the
/// strategy's revision, which any add, delete or move moves on.
class SeenPage {
  const SeenPage({
    required this.name,
    required this.isAttack,
    required this.content,
  });

  /// [page]'s name and side as drawn, with [read]'s content if this device
  /// has read it.
  factory SeenPage.of(DrawnPage page, RemotePageSnapshot? read) => SeenPage(
        name: page.name,
        isAttack: page.isAttack,
        content: read == null ? null : _contentOf(read),
      );

  final String name;
  final bool isAttack;

  /// The revision of everything the page shows: its settings (`content`),
  /// and each element (`element:<id>`) and lineup (`lineup:<id>`) not
  /// deleted. Every change to one moves its revision on. Null when this
  /// device never read the page's content: then the delete always waits
  /// for the user (see [unchangedIn]).
  final Map<String, int>? content;

  static Map<String, int> _contentOf(RemotePageSnapshot read) => {
        'content': read.content.revision,
        for (final element in read.elements)
          if (!element.deleted) 'element:${element.publicId}': element.revision,
        for (final lineup in read.lineups)
          if (!lineup.deleted) 'lineup:${lineup.publicId}': lineup.revision,
      };

  /// Whether [now], a fresh read of the page, shows it as seen. Without
  /// the content as seen, nothing says a teammate did not change it, so it
  /// never does.
  bool unchangedIn(RemotePageSnapshot now) {
    final seen = content;
    return seen != null &&
        now.page.name == name &&
        now.page.isAttack == isAttack &&
        _sameRevisions(seen, _contentOf(now));
  }

  static bool _sameRevisions(Map<String, int> left, Map<String, int> right) =>
      left.length == right.length &&
      left.entries.every((entry) => right[entry.key] == entry.value);

  /// The page as seen once this device's own [op] to it landed, applied at
  /// [revision]: the change is not taken for a teammate's. A part some
  /// other change moved on since it was seen stays as seen, so that one
  /// still counts.
  SeenPage after(StrategyOp op, int revision) {
    if (op is PagePatchOp) {
      return SeenPage(
        name: op.payload['name'] as String? ?? name,
        isAttack: op.payload['isAttack'] as bool? ?? isAttack,
        content: content,
      );
    }
    final seen = content;
    final key = switch (op.entityType) {
      StrategyOpEntityType.pageContent => 'content',
      StrategyOpEntityType.element => 'element:${op.entityPublicId}',
      StrategyOpEntityType.lineup => 'lineup:${op.entityPublicId}',
      _ => null,
    };
    if (seen == null || key == null) return this;
    final before = seen[key];
    final isNew = before == null && op.kind == StrategyOpKind.add;
    if (before != revision - 1 && !isNew) return this;
    return SeenPage(
      name: name,
      isAttack: isAttack,
      content: {
        for (final entry in seen.entries)
          if (entry.key != key) entry.key: entry.value,
        if (op.kind != StrategyOpKind.delete) key: revision,
      },
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'isAttack': isAttack,
        if (content != null) 'content': content,
      };

  /// Throws a FormatException when [json] is not a seen page.
  factory SeenPage.fromJson(Object? json) {
    if (json is! Map ||
        json['name'] is! String ||
        json['isAttack'] is! bool ||
        (json['content'] != null && json['content'] is! Map)) {
      throw const FormatException('Outbox seenPage is malformed');
    }
    final content = json['content'] as Map?;
    return SeenPage(
      name: json['name'] as String,
      isAttack: json['isAttack'] as bool,
      content: content == null
          ? null
          : {
              for (final entry in content.entries)
                entry.key as String: entry.value is num
                    ? (entry.value as num).toInt()
                    : throw const FormatException(
                        'Outbox seenPage is malformed'),
            },
    );
  }
}

/// The reason a delete waits for the user when its page changed since this
/// device saw it (see SeenPage): "<page name> $pageChangedSinceDeleteReason".
const pageChangedSinceDeleteReason = 'changed since you deleted it';

/// The reason a delete waits for the user when this device never had the
/// page's content to compare a fresh read with (SeenPage.content is null):
/// "<page name> $pageUncheckedBeforeDeleteReason".
const pageUncheckedBeforeDeleteReason =
    "couldn't be checked for a teammate's changes";

/// The reason a delete of the page seen as [seen] waits for the user, once
/// a fresh read of the page did not show it as seen (SeenPage.unchangedIn).
String heldPageDeleteReason(SeenPage seen) => seen.content == null
    ? '${seen.name} $pageUncheckedBeforeDeleteReason'
    : '${seen.name} $pageChangedSinceDeleteReason';

/// The page name in [reason], when it is the reason a page delete is held
/// for the user (see heldPageDeleteReason), and whether this device could
/// check the page at all. Reasons saved by older builds read too: they are
/// all the "changed" kind. The name comes first and may hold either
/// reason's words itself, so the last one found is the reason.
({String page, bool checked})? heldPageDelete(String reason) {
  final changed = reason.lastIndexOf(' $pageChangedSinceDeleteReason');
  final unchecked = reason.lastIndexOf(' $pageUncheckedBeforeDeleteReason');
  if (changed < 0 && unchecked < 0) return null;
  return unchecked > changed
      ? (page: reason.substring(0, unchecked), checked: false)
      : (page: reason.substring(0, changed), checked: true);
}

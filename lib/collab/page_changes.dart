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
  });

  final String publicId;
  final String name;
  final bool isAutoNamed;
  final bool isAttack;

  /// The page's revision on the server as last read; null for a page whose
  /// add has not landed (the server makes it at revision 1).
  final int? revision;

  DrawnPage copyWith({String? name, bool? isAutoNamed, bool? isAttack}) =>
      DrawnPage(
        publicId: publicId,
        name: name ?? this.name,
        isAutoNamed: isAutoNamed ?? this.isAutoNamed,
        isAttack: isAttack ?? this.isAttack,
        revision: revision,
      );

  @override
  bool operator ==(Object other) =>
      other is DrawnPage &&
      other.publicId == publicId &&
      other.name == name &&
      other.isAutoNamed == isAutoNamed &&
      other.isAttack == isAttack &&
      other.revision == revision;

  @override
  int get hashCode =>
      Object.hash(publicId, name, isAutoNamed, isAttack, revision);
}

/// [serverPages] in order, with [changes] applied the way the server
/// applies them (convex/ops.ts applyPageOp), in the order given. Changes
/// the server would refuse or find nothing to do for (a page already gone,
/// or added twice) change nothing here either.
List<DrawnPage> drawPages(
  Iterable<RemotePage> serverPages,
  Iterable<StrategyOp> changes,
) {
  final ordered = [...serverPages]
    ..sort((left, right) => left.sortIndex.compareTo(right.sortIndex));
  final pages = [
    for (final page in ordered)
      DrawnPage(
        publicId: page.publicId,
        name: page.name,
        isAutoNamed: page.isAutoNamed == true,
        isAttack: page.isAttack,
        revision: page.revision,
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
      case PageAddOp(:final pagePublicId, :final payload, :final sortIndex):
        if (indexOf(pagePublicId) >= 0) continue;
        pages.insert(
          sortIndex.clamp(0, pages.length),
          DrawnPage(
            publicId: pagePublicId,
            name: payload['name'] as String? ?? 'Page',
            isAutoNamed: payload['isAutoNamed'] == true,
            isAttack: payload['isAttack'] as bool? ?? true,
            revision: null,
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

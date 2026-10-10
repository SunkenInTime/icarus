import 'package:uuid/uuid.dart';

/// Ids of placed items copied to another page of a cloud strategy.
///
/// A local strategy keeps a copied item's id: each page holds its own list,
/// and the page transition pairs the two by id, so the item glides from one
/// page to the next. The server keeps one row per item id, so a cloud copy
/// needs an id of its own. It gets `<root>~cp1~<uuid>`: the root is the id
/// of the item first copied, and a copy of a copy keeps that root, so ids
/// never nest. The transition pairs items by root when their ids differ.
///
/// Storage, ops, edits, deletes and undo use the full id. The root is only
/// read to pair items across pages and to see whether a page already has one.
const _copyMark = '~cp1~';

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// The id [id] was first copied from, or [id] itself when it is no copy.
/// Only an id ending in the mark and a canonical uuid is a copy, so an id
/// that merely contains `~` (imports take any string) stays its own root.
String pageCopyRoot(String id) {
  final at = id.lastIndexOf(_copyMark);
  if (at <= 0) return id;
  final occurrence = id.substring(at + _copyMark.length);
  return _uuid.hasMatch(occurrence) ? id.substring(0, at) : id;
}

/// A fresh id for a copy of [id] on another page.
String newPageCopyId(String id) =>
    '${pageCopyRoot(id)}$_copyMark${const Uuid().v4()}';

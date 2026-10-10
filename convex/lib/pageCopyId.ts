/// Ids of items copied to another page, as the app writes them (see
/// lib/const/page_copy_id.dart, which this mirrors): `<root>~cp1~<uuid>`,
/// where the root is the id of the item first copied. A copy of a copy keeps
/// that root, so ids never nest, and the app's page transition pairs items
/// across pages by root, so a copied item glides from one page to the next.

const copyMark = "~cp1~";

const uuid =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/// The id `id` was first copied from, or `id` itself when it is no copy.
/// Only an id ending in the mark and a canonical uuid is a copy, so an id
/// that merely contains `~` (imports take any string) stays its own root.
export function pageCopyRoot(id: string): string {
  const at = id.lastIndexOf(copyMark);
  if (at <= 0) return id;
  return uuid.test(id.substring(at + copyMark.length))
    ? id.substring(0, at)
    : id;
}

/// The longest root a copy keeps, URL-encoded. The app stores each queued
/// change under a key of about 120 characters plus the item's encoded id
/// (DurableOutboxRecord.createStorageKey), and its storage refuses keys over
/// 255, so a copy of an item imported with an unusually long id gets a plain
/// id instead: it then fades between pages rather than gliding.
const maxKeptRootLength = 80;

/// A new id for a copy of `id`, made with `freshId`: `<root>~cp1~<fresh>`.
export function pageCopyId(id: string, freshId: () => string): string {
  const root = pageCopyRoot(id);
  const fresh = freshId();
  return encodeURIComponent(root).length > maxKeptRootLength
    ? fresh
    : `${root}${copyMark}${fresh}`;
}

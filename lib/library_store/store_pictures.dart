import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus_library/icarus_library.dart';

sealed class PagePictures {
  const PagePictures();
}

final class PicturesOnPage extends PagePictures {
  PicturesOnPage(Set<String> referenced, Map<String, PictureAsset> known)
      : referenced = Set.unmodifiable(referenced),
        known = Map.unmodifiable(known);

  final Set<String> referenced;
  final Map<String, PictureAsset> known;

  Set<String> get unknown => referenced.difference(known.keys.toSet());
}

enum PicturesNotListed { contentNotRead, unreadableRows }

final class PicturesNotKnown extends PagePictures {
  const PicturesNotKnown(this.why);

  final PicturesNotListed why;
}

PagePictures picturesOf(PageContent page) {
  final ContentShown shown;
  switch (page.content) {
    case final ContentShown content:
      shown = content;
    case ContentNotRead():
      return const PicturesNotKnown(PicturesNotListed.contentNotRead);
  }
  if (page.unknownKinds.isNotEmpty || page.unplaced.isNotEmpty) {
    return const PicturesNotKnown(PicturesNotListed.unreadableRows);
  }
  final referenced = <String>{};
  for (final element in page.elements) {
    switch (element) {
      case LiveElement(:final publicId, :final payload)
          when payload.kind == ElementKind.image:
        referenced.add(switch (payload.data[pictureIdField]) {
          final String id when id.isNotEmpty => id,
          _ => publicId,
        });
      case UnreadableElement():
        return const PicturesNotKnown(PicturesNotListed.unreadableRows);
      case _:
        break;
    }
  }
  final groups = <LiveLineupGroup>[];
  for (final group in page.lineupGroups) {
    switch (group) {
      case final LiveLineupGroup live:
        groups.add(live);
      case UnreadableLineupGroup():
        return const PicturesNotKnown(PicturesNotListed.unreadableRows);
      case _:
        break;
    }
  }
  final graph = lineupGraphOfGroups(page.page.publicId, groups);
  if (graph == null) {
    return const PicturesNotKnown(PicturesNotListed.unreadableRows);
  }
  for (final link in graph.links) {
    for (final image in link.images) {
      referenced.add(image.id);
    }
  }
  return PicturesOnPage(referenced, shown.pictures);
}

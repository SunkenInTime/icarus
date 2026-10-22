import 'package:icarus/collab/generated/generated.dart';

// A live page read in parts. Convex re-runs a live query in full whenever a
// row it read is written, so watching page:getSnapshot re-reads every row of
// the page after every edit. Watched as page:getFrame plus page:getElementSlice
// for id ranges that together cover every id, an edit re-runs only the slice
// holding the row it touched. Each part is complete for what it covers, so
// the page put together from them is the whole page, as page:getSnapshot
// sends it.

const _hexDigits = '0123456789abcdef';

/// Where each slice of a page with about [elementCount] elements starts. The
/// first starts at the empty id and each runs to the next one's start, the
/// last to the end, so together they hold every id. Element ids are random
/// UUIDs, so hexadecimal starts split a page evenly: about ten elements a
/// slice, between 1 and 16 slices.
List<String> pageSliceStarts(int elementCount) {
  final count = elementCount < 16
      ? 1
      : elementCount < 32
          ? 2
          : elementCount < 64
              ? 4
              : elementCount < 128
                  ? 8
                  : 16;
  return [
    for (var index = 0; index < count; index++)
      index == 0 ? '' : _hexDigits[index * 16 ~/ count],
  ];
}

/// The whole page from its [frame] and every one of its [slices]: elements
/// and lineups in place order, ties by id as the offline copy orders them,
/// and each asset once. Like page:getSnapshot read with picture ids, less
/// the picture aliases only builds without them read.
PageGetSnapshotResult assemblePage(
  PageGetFrameResult frame,
  List<PageGetElementSliceResult> slices,
) {
  final assets = <String, ImagesListForStrategyResultItem>{
    for (final asset in [
      ...frame.assets,
      for (final slice in slices) ...slice.assets,
    ])
      asset.publicId: asset,
  };
  int byPlace(
      double leftSort, String leftId, double rightSort, String rightId) {
    final bySort = leftSort.compareTo(rightSort);
    return bySort != 0 ? bySort : leftId.compareTo(rightId);
  }

  return PageGetSnapshotResult(
    page: frame.page,
    content: frame.content,
    elements: [for (final slice in slices) ...slice.elements]..sort(
        (left, right) => byPlace(
            left.sortIndex, left.publicId, right.sortIndex, right.publicId)),
    lineups: [...frame.lineups]..sort((left, right) => byPlace(
        left.sortIndex, left.publicId, right.sortIndex, right.publicId)),
    assets: assets.values.toList()
      ..sort((left, right) => left.publicId.compareTo(right.publicId)),
  );
}

/// The page each time its parts answer, from [parts]: the frame and then
/// every slice in order, watched together (ConvexQuery.watchTogether) so
/// they always come from one server state. Watched one by one, a write that
/// touches two slices could show in one before the other, and the page put
/// together in between would be one the server never held.
Stream<PageGetSnapshotResult> assembledPages(Stream<List<Object?>> parts) =>
    parts.map(
      (parts) => assemblePage(
        parts.first! as PageGetFrameResult,
        parts.skip(1).cast<PageGetElementSliceResult>().toList(),
      ),
    );

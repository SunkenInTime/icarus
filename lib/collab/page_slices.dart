import 'dart:async';

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

/// The page whenever any part answers, once every part has. Parts that
/// answer together (one write touching several slices) are put together
/// once. An error from any part ends the page.
Stream<PageGetSnapshotResult> watchAssembledPage(
  Stream<PageGetFrameResult> frame,
  List<Stream<PageGetElementSliceResult>> slices,
) {
  late final StreamController<PageGetSnapshotResult> controller;
  final subscriptions = <StreamSubscription<Object?>>[];
  PageGetFrameResult? latestFrame;
  final latestSlices = List<PageGetElementSliceResult?>.filled(
    slices.length,
    null,
  );
  var emitScheduled = false;

  void emitSoon() {
    if (emitScheduled) return;
    emitScheduled = true;
    scheduleMicrotask(() {
      emitScheduled = false;
      final frameNow = latestFrame;
      if (controller.isClosed || frameNow == null) return;
      if (latestSlices.any((slice) => slice == null)) return;
      controller.add(
        assemblePage(frameNow, latestSlices.cast<PageGetElementSliceResult>()),
      );
    });
  }

  controller = StreamController<PageGetSnapshotResult>(
    onListen: () {
      subscriptions.add(frame.listen(
        (value) {
          latestFrame = value;
          emitSoon();
        },
        onError: controller.addError,
      ));
      for (final (index, slice) in slices.indexed) {
        subscriptions.add(slice.listen(
          (value) {
            latestSlices[index] = value;
            emitSoon();
          },
          onError: controller.addError,
        ));
      }
    },
    onPause: () {
      for (final subscription in subscriptions) {
        subscription.pause();
      }
    },
    onResume: () {
      for (final subscription in subscriptions) {
        subscription.resume();
      }
    },
    onCancel: () async {
      await Future.wait(
        subscriptions.map((subscription) => subscription.cancel()),
      );
      subscriptions.clear();
    },
  );
  return controller.stream;
}

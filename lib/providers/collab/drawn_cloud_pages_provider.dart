import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/page_changes.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';

/// The open cloud strategy's pages as this device draws them, in order:
/// the last read of the server's (or of this computer's copy), with this
/// device's page changes on top until a read shows them (see
/// StrategyOpQueueNotifier.pageChangesToDraw). Null until a read arrives.
final drawnCloudPagesProvider = Provider<DrawnPages?>((ref) {
  final snapshot = ref.watch(remoteEditorSnapshotProvider).valueOrNull;
  if (snapshot == null) return null;
  ref.watch(strategyOpQueueProvider);
  final queue = ref.read(strategyOpQueueProvider.notifier);
  return DrawnPages(drawPages(
    snapshot.pages,
    queue.pageChangesToDraw(snapshot),
    pageRevisions: queue.landedPageRevisions(snapshot),
  ));
});

/// A list of drawn pages that compares by its pages, so what reads it
/// rebuilds only when a page it shows changes.
@immutable
class DrawnPages {
  const DrawnPages(this.pages);

  final List<DrawnPage> pages;

  DrawnPage? byId(String pageId) =>
      pages.where((page) => page.publicId == pageId).firstOrNull;

  @override
  bool operator ==(Object other) =>
      other is DrawnPages && listEquals(other.pages, pages);

  @override
  int get hashCode => Object.hashAll(pages);
}

import 'package:collection/collection.dart';

extension SortIndexOrder<T> on List<T> {
  /// Sorts by sortIndex, keeping the current order within ties.
  ///
  /// Ties are real: legacy pages carry duplicate sortIndexes, and two clients
  /// adding at once can both pick max+1. The server returns tied rows in
  /// creation order. List.sort is not stable, so it could swap tied items
  /// between two loads of the same data.
  void sortBySortIndex(int Function(T item) sortIndexOf) {
    mergeSort<T>(
      this,
      compare: (a, b) => sortIndexOf(a).compareTo(sortIndexOf(b)),
    );
  }
}

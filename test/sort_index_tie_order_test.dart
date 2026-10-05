import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';

// Legacy pages carry duplicate sortIndexes, and two clients adding at once can
// both pick max+1. The server returns tied rows in creation order, so every
// client must keep that order; otherwise tied items flip stacking between two
// loads of the same data.
void main() {
  // Enough rows that Dart's List.sort leaves insertion sort for quicksort.
  const count = 60;
  int tiedSortIndex(int i) => i % 3;

  List<String> expectedTieOrder() {
    final ids = [for (var i = 0; i < count; i++) 'item-$i'];
    return [
      for (var group = 0; group < 3; group++)
        ...ids
            .where((id) => tiedSortIndex(int.parse(id.split('-')[1])) == group),
    ];
  }

  test('elements keep the server order within sortIndex ties', () {
    final elements = [
      for (var i = 0; i < count; i++)
        RemoteElement(
          publicId: 'item-$i',
          strategyPublicId: 'strategy',
          pagePublicId: 'page',
          elementType: 'agent',
          payload: const <String, dynamic>{},
          sortIndex: tiedSortIndex(i),
          revision: 1,
          deleted: false,
        ),
    ];

    final grouped = RemoteFullStrategySnapshot.groupElementsByPage(elements);

    expect(
      grouped['page']!.map((element) => element.publicId).toList(),
      expectedTieOrder(),
    );
  });

  test('lineups keep the server order within sortIndex ties', () {
    final lineups = [
      for (var i = 0; i < count; i++)
        RemoteLineup(
          publicId: 'item-$i',
          strategyPublicId: 'strategy',
          pagePublicId: 'page',
          payload: const <String, dynamic>{},
          sortIndex: tiedSortIndex(i),
          revision: 1,
          deleted: false,
        ),
    ];

    final grouped = RemoteFullStrategySnapshot.groupLineupsByPage(lineups);

    expect(
      grouped['page']!.map((lineup) => lineup.publicId).toList(),
      expectedTieOrder(),
    );
  });
}

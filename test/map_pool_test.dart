import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';

void main() {
  // Pick a map and the editor's map selector only offer these two lists, so a
  // map left out of both during a rotation can't be picked at all.
  test('every map is in exactly one of the two lists', () {
    expect([
      ...Maps.availableMaps,
      ...Maps.outofplayMaps,
    ], unorderedEquals(MapValue.values));
  });
}

import 'package:flutter_test/flutter_test.dart';
import '../tool/check_bundled_wall_heights.dart';

void main() {
  Map<String, dynamic> model(List<dynamic> bands, {bool known = true}) => {
        'walls': [
          {
            'id': 'reviewed-wall',
            'unknownHeight': !known,
            'floorElevationMeters': 0,
            'reviewStatus': 'reviewed',
            'bands': bands,
          }
        ],
      };

  test('release rejects the old reviewed infinite-height fallback', () {
    expect(
        unresolvedWallHeights(model([
          [0, null]
        ])),
        ['reviewed-wall']);
    expect(
        unresolvedWallHeights(model([
          [0, double.infinity]
        ])),
        ['reviewed-wall']);
    expect(
        unresolvedWallHeights(model([
          [0, 4]
        ], known: false)),
        ['reviewed-wall']);
  });
  test('release preserves finite windows and nonblocking annotations', () {
    expect(
        unresolvedWallHeights(model([
          [0, 5.7],
          [8.8, 15.5]
        ])),
        isEmpty);
    expect(unresolvedWallHeights(model([])), isEmpty);
  });
  test('release rejects invalid lower heights and empty data', () {
    expect(
        unresolvedWallHeights(model([
          [0, 0]
        ])),
        ['reviewed-wall']);
    expect(
        unresolvedWallHeights(model([
          [double.nan, 4]
        ])),
        ['reviewed-wall']);
    expect(
        unresolvedWallHeights(model([
          [5, 4]
        ])),
        ['reviewed-wall']);
    expect(unresolvedWallHeights({'walls': []}), isNotEmpty);
  });
}

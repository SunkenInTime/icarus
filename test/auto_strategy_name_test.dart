import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/strategy_provider.dart';

void main() {
  group('autoStrategyName', () {
    test('uses the map name when it is free', () {
      expect(autoStrategyName(MapValue.haven, const []), 'Haven');
      expect(autoStrategyName(MapValue.haven, const ['Ascent']), 'Haven');
    });

    test('appends the first free number when the name is taken', () {
      expect(autoStrategyName(MapValue.haven, const ['Haven']), 'Haven 2');
      expect(
        autoStrategyName(MapValue.haven, const ['Haven', 'Haven 2']),
        'Haven 3',
      );
      expect(
        autoStrategyName(MapValue.haven, const ['Haven', 'Haven 3']),
        'Haven 2',
      );
    });

    test('ignores case and surrounding whitespace in existing names', () {
      expect(autoStrategyName(MapValue.haven, const [' haven ']), 'Haven 2');
    });
  });
}

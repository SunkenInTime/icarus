import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_life_forward_test.dart' show thirdLife;
import 'cloud_set_aside_test.dart' show laterLife, replaced;
import 'cloud_support.dart';
import 'support.dart';

void main() {
  test('two replacements keep two generations, each with its own lives, '
      'and no two kept entries share a place', () {
    final client = Client();
    client.edit(movePatch('first'));
    client.read(replaced(initialRows()));
    client.edit(movePatch('second', elementId: 'e2'));
    client.read(replaced(initialRows(), life: thirdLife));
    final generations = switch (client.queue.strategy.setAside) {
      SetAside(:final generations) => generations,
      NothingSetAside() => fail('nothing set aside'),
    };
    expect(
      [
        for (final generation in generations)
          (
            generation.writtenIn,
            generation.replacedBy,
            [for (final entry in generation.entries) entry.id].join(', '),
          ),
      ],
      [
        (strategyCreatedAt.millisecondsSinceEpoch, laterLife, 'first'),
        (laterLife, thirdLife, 'second'),
      ],
    );
    final places = [
      for (final generation in generations)
        for (final entry in generation.entries) entry.place,
    ];
    expect(places.toSet(), hasLength(places.length));
  });
}

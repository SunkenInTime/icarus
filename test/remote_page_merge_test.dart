import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/strategy/remote_page_merge.dart';

void main() {
  List<String> merge(
          List<String> current, List<String> incoming, Set<String> held) =>
      mergeRemoteItems(
        current: current,
        incoming: incoming,
        idOf: (id) => id.split(':').first,
        keep: held.contains,
      );

  test('takes the server copy of everything not held, in server order', () {
    expect(merge(['a:1', 'b:1'], ['b:2', 'c:1', 'a:2'], {}),
        ['b:2', 'c:1', 'a:2']);
  });

  test('a held item keeps its screen copy', () {
    expect(merge(['a:1', 'b:1'], ['a:2', 'b:2'], {'a'}), ['a:1', 'b:2']);
  });

  test('a held item the server removed stays in its place', () {
    expect(merge(['a:1', 'b:1', 'c:1'], ['b:1', 'c:1'], {'a'}),
        ['a:1', 'b:1', 'c:1']);
    expect(merge(['a:1', 'b:1', 'c:1'], ['a:1', 'c:1'], {'b'}),
        ['a:1', 'b:1', 'c:1']);
  });

  test('an unheld item the server removed goes', () {
    expect(merge(['a:1', 'b:1'], ['b:1'], {'b'}), ['b:1']);
  });
}

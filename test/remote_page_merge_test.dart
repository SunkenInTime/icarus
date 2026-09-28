import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/strategy/remote_page_merge.dart';

void main() {
  // Items are 'id:version'; an item changed when its version differs.
  List<String> merge(
    List<String> current,
    List<String> incoming, {
    Set<String> held = const {},
    Set<String>? changed,
  }) {
    String id(String item) => item.split(':').first;
    return mergeRemoteItems(
      current: current,
      incoming: incoming,
      idOf: id,
      rule: RemoteMergeRule(
        held: held.contains,
        changed: (itemId) =>
            changed?.contains(itemId) ??
            !current.contains(
                incoming.firstWhere((i) => id(i) == itemId, orElse: () => '')),
      ),
    );
  }

  test('takes the server copy of what changed, in server order', () {
    expect(merge(['a:1', 'b:1'], ['b:2', 'c:1', 'a:2']), ['b:2', 'c:1', 'a:2']);
  });

  test('an unchanged item stays the object on screen', () {
    final onScreen = ['a:1', 'b:1'];
    final merged = merge(onScreen, ['a:1', 'b:2'], changed: {'b'});
    expect(identical(merged.first, onScreen.first), isTrue);
    expect(merged.last, 'b:2');
  });

  test('a held item keeps its screen copy', () {
    expect(merge(['a:1', 'b:1'], ['a:2', 'b:2'], held: {'a'}), ['a:1', 'b:2']);
  });

  test('a held item the server removed stays in its place', () {
    expect(merge(['a:1', 'b:1', 'c:1'], ['b:1', 'c:1'], held: {'a'}),
        ['a:1', 'b:1', 'c:1']);
    expect(merge(['a:1', 'b:1', 'c:1'], ['a:1', 'c:1'], held: {'b'}),
        ['a:1', 'b:1', 'c:1']);
  });

  test('an unheld item the server removed goes, changed or not', () {
    expect(merge(['a:1', 'b:1'], ['b:1'], changed: {}), ['b:1']);
  });
}

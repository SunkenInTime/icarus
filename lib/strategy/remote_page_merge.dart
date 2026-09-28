import 'dart:math' show min;

/// How a page merge treats each item already on screen.
class RemoteMergeRule {
  const RemoteMergeRule({required this.held, required this.changed});

  /// The user is mid-way through changing the item: it stays as on screen,
  /// even when the server removed it.
  final bool Function(String id) held;

  /// The server's copy differs from the one the canvas last drew.
  final bool Function(String id) changed;

  /// The item stays the object on screen: its widget keeps whatever
  /// in-progress state it holds, and nothing about it is rebuilt.
  bool keepsScreenCopy(String id) => held(id) || !changed(id);
}

/// The server's copy of a page's items ([incoming]), with every item [rule]
/// keeps as the object already on screen.
///
/// Items keep the server's order. An item the server removed goes, unless it
/// is held; then it keeps its place on screen, so live sync, which reads
/// order from list position, sees no move the user never made.
List<T> mergeRemoteItems<T>({
  required List<T> current,
  required List<T> incoming,
  required String Function(T item) idOf,
  required RemoteMergeRule rule,
}) {
  final currentById = {for (final item in current) idOf(item): item};
  final incomingIds = {for (final item in incoming) idOf(item)};
  final merged = [
    for (final item in incoming)
      if (currentById[idOf(item)] case final onScreen?
          when rule.keepsScreenCopy(idOf(item)))
        onScreen
      else
        item,
  ];
  for (final (index, item) in current.indexed) {
    if (!incomingIds.contains(idOf(item)) && rule.held(idOf(item))) {
      merged.insert(min(index, merged.length), item);
    }
  }
  return merged;
}

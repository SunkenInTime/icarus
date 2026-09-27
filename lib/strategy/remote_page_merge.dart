/// The server's copy of a page's items ([incoming]), except the ones [keep]
/// names: those stay the object on screen, so the widget keeps whatever
/// in-progress state it holds, and stay even when the server removed them.
///
/// Items keep the server's order; a kept item the server removed goes last.
List<T> mergeRemoteItems<T>({
  required List<T> current,
  required List<T> incoming,
  required String Function(T item) idOf,
  required bool Function(String id) keep,
}) {
  final currentById = {for (final item in current) idOf(item): item};
  final incomingIds = {for (final item in incoming) idOf(item)};
  return [
    for (final item in incoming)
      if (currentById[idOf(item)] case final onScreen? when keep(idOf(item)))
        onScreen
      else
        item,
    for (final item in current)
      if (!incomingIds.contains(idOf(item)) && keep(idOf(item))) item,
  ];
}

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

typedef ScreenMatch = ({RenderBox box, Offset at});

List<ScreenMatch> screenMatches(bool Function(Widget) test) {
  final found = <ScreenMatch>[];
  void visit(Element element) {
    if (test(element.widget)) {
      final box = element.findRenderObject();
      if (box is RenderBox && box.hasSize && box.attached) {
        found.add(
          (box: box, at: box.localToGlobal(box.size.center(Offset.zero))),
        );
      }
    }
    element.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  return found;
}

HitTestResult _hitAt(Offset at) {
  final result = HitTestResult();
  WidgetsBinding.instance.hitTestInView(
    result,
    at,
    WidgetsBinding.instance.platformDispatcher.implicitView!.viewId,
  );
  return result;
}

bool _onScreen(Offset at) {
  final view = WidgetsBinding.instance.platformDispatcher.implicitView!;
  return (Offset.zero & view.physicalSize / view.devicePixelRatio).contains(at);
}

bool clickReaches(RenderObject target, Offset at) {
  final path = _hitAt(at).path;
  if (path.isEmpty) return false;
  if (path.any((entry) => identical(entry.target, target))) return true;
  final first = path.first.target;
  if (first is RenderView) return false;
  for (RenderObject? above = target.parent;
      above != null;
      above = above.parent) {
    if (identical(above, first)) return true;
  }
  return false;
}

String coverAt(Offset at) {
  final made = <RenderObject, Element>{};
  void visit(Element element) {
    if (element is RenderObjectElement) made[element.renderObject] = element;
    element.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  for (final entry in _hitAt(at).path) {
    final element = made[entry.target];
    if (element == null) continue;
    final own = element.widget.key;
    String? keyed = own is ValueKey || own is ObjectKey
        ? '${element.widget.runtimeType} $own'
        : null;
    if (keyed != null) return keyed;
    element.visitAncestorElements((ancestor) {
      final key = ancestor.widget.key;
      if (key is ValueKey || key is ObjectKey) {
        keyed = '${ancestor.widget.runtimeType} $key';
        return false;
      }
      return true;
    });
    final hit = '${element.widget.runtimeType}';
    return keyed == null ? hit : '$hit under $keyed';
  }
  return 'nothing';
}

Offset clickableCenterOf(
  bool Function(Widget) test, {
  required String what,
  int nth = 0,
  void Function(String)? note,
}) {
  final found = screenMatches(test);
  final reachable = [
    for (final match in found)
      if (clickReaches(match.box, match.at)) match,
  ];
  if (reachable.length > nth) {
    final picked = reachable[nth];
    if (found.length > nth && !identical(found[nth].box, picked.box)) {
      note?.call('TAP $what: the match the tree holds first is covered by '
          '${coverAt(found[nth].at)}; the one a click reaches is used');
    }
    return picked.at;
  }
  if (reachable.length == found.length) {
    throw StateError('$what: found ${found.length}');
  }
  final covered = found.firstWhere((match) => !reachable.contains(match));
  final count = reachable.isEmpty ? 'all' : found.length - reachable.length;
  final why = _onScreen(covered.at)
      ? 'covered by ${coverAt(covered.at)}'
      : 'off screen, at ${covered.at}';
  throw StateError('$what: found ${found.length}, $count $why');
}

List<Offset> clickableCentersOf(bool Function(Widget) test) => [
      for (final match in screenMatches(test))
        if (clickReaches(match.box, match.at)) match.at,
    ];

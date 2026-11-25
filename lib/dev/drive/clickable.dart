import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

typedef TreeMatch = ({RenderBox box, Offset at});

List<TreeMatch> matchesInTree(bool Function(Widget) test) {
  final found = <TreeMatch>[];
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

List<RenderObject> _hitAt(Offset at) {
  final result = HitTestResult();
  WidgetsBinding.instance.hitTestInView(
    result,
    at,
    WidgetsBinding.instance.platformDispatcher.implicitView!.viewId,
  );
  return [
    for (final entry in result.path)
      if (entry.target case final RenderObject target) target,
  ];
}

bool _onScreen(Offset at) {
  final view = WidgetsBinding.instance.platformDispatcher.implicitView!;
  return (Offset.zero & view.physicalSize / view.devicePixelRatio).contains(at);
}

bool _within(RenderObject node, RenderObject outer) {
  for (RenderObject? at = node; at != null; at = at.parent) {
    if (identical(at, outer)) return true;
  }
  return false;
}

RenderPointerListener? _handlerOf(RenderObject node) {
  for (RenderObject? at = node; at != null; at = at.parent) {
    if (at is RenderPointerListener) return at;
  }
  return null;
}

bool takesTheTap(RenderObject match, Offset at) {
  if (!_onScreen(at)) return false;
  final path = _hitAt(at);
  final own = _handlerOf(match);
  if (own == null) {
    final first = path.firstOrNull;
    return first != null && first is! RenderView && _within(first, match);
  }
  final first = path.whereType<RenderPointerListener>().firstOrNull;
  return first != null && (identical(first, own) || _within(first, match));
}

String _named(RenderObject target) {
  Element? made;
  void visit(Element element) {
    if (made != null) return;
    if (element is RenderObjectElement &&
        identical(element.renderObject, target)) {
      made = element;
      return;
    }
    element.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  final element = made;
  if (element == null) return '${target.runtimeType}';
  const plumbing = {
    'Listener',
    'RawGestureDetector',
    'MouseRegion',
    'Semantics',
  };
  var name = '${element.widget.runtimeType}';
  String? keyed;
  var named = !plumbing.contains(name) && !name.startsWith('_');
  void keyOf(Widget widget) {
    final key = widget.key;
    if (key is ValueKey || key is ObjectKey) {
      keyed = '${widget.runtimeType} $key';
    }
  }

  keyOf(element.widget);
  element.visitAncestorElements((ancestor) {
    final type = '${ancestor.widget.runtimeType}';
    if (!named && !plumbing.contains(type) && !type.startsWith('_')) {
      name = type;
      named = true;
    }
    if (keyed == null) keyOf(ancestor.widget);
    return keyed == null;
  });
  return keyed == null || keyed!.startsWith('$name ')
      ? keyed ?? name
      : '$name under $keyed';
}

String whyNotTapped(Offset at) {
  if (!_onScreen(at)) {
    return 'off screen, at (${at.dx.round()}, ${at.dy.round()})';
  }
  final path = _hitAt(at);
  final handler = path.whereType<RenderPointerListener>().firstOrNull;
  if (handler != null) return 'the tap goes to ${_named(handler)}';
  final first = path.firstOrNull;
  return first == null || first is RenderView
      ? 'nothing there takes the tap'
      : 'the tap reaches ${_named(first)}, which takes no taps';
}

String _ordinal(int n) => switch (n % 100) {
      11 || 12 || 13 => '${n}th',
      _ => switch (n % 10) {
          1 => '${n}st',
          2 => '${n}nd',
          3 => '${n}rd',
          _ => '${n}th',
        },
    };

Offset clickableCenterOf(
  bool Function(Widget) test, {
  required String what,
  int nth = 0,
  void Function(String)? note,
}) {
  final found = matchesInTree(test);
  final tappable = [
    for (final match in found)
      if (takesTheTap(match.box, match.at)) match,
  ];
  final untapped = [
    for (final match in found)
      if (!tappable.contains(match)) match,
  ];
  if (tappable.length > nth) {
    final picked = tappable[nth];
    final index = found.indexOf(picked);
    if (index != nth) {
      note?.call('TAP $what: the ${_ordinal(nth + 1)} match that can be '
          'tapped is the ${_ordinal(index + 1)} of ${found.length} in the '
          'tree; ${untapped.length} cannot be tapped, the first because '
          '${whyNotTapped(untapped.first.at)}');
    }
    return picked.at;
  }
  if (found.isEmpty) throw StateError('$what: found 0');
  final asked = nth == 0 ? '' : ', asked for the ${_ordinal(nth + 1)}';
  if (untapped.isEmpty) {
    throw StateError('$what: found ${found.length}, all can be tapped$asked');
  }
  final can = tappable.isEmpty ? 'none' : '${tappable.length}';
  throw StateError('$what: found ${found.length}, $can can be tapped$asked; '
      'the first that cannot: ${whyNotTapped(untapped.first.at)}');
}

List<Offset> clickableCentersOf(bool Function(Widget) test) => [
      for (final match in matchesInTree(test))
        if (takesTheTap(match.box, match.at)) match.at,
    ];

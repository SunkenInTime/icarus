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

bool insideTheWindow(Offset at) {
  final view = WidgetsBinding.instance.platformDispatcher.implicitView!;
  return (Offset.zero & view.physicalSize / view.devicePixelRatio).contains(at);
}

bool _within(RenderObject node, RenderObject outer) {
  for (RenderObject? at = node; at != null; at = at.parent) {
    if (identical(at, outer)) return true;
  }
  return false;
}

RenderObject? _rootOverlay() {
  RenderObject? found;
  void visit(Element element) {
    if (found != null) return;
    if (element.widget is Overlay) {
      found = element.findRenderObject();
      return;
    }
    element.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  return found;
}

bool Function(RenderObject) _takesTapsBelow(RenderObject? overlay) => (node) =>
    node is RenderPointerListener &&
    node.onPointerDown != null &&
    (overlay == null || _within(node, overlay));

RenderObject? _handlerFrom(
  RenderObject? node,
  bool Function(RenderObject) takesTaps,
) {
  for (RenderObject? at = node; at != null; at = at.parent) {
    if (takesTaps(at)) return at;
  }
  return null;
}

bool _drawnAt(RenderObject match, RenderObject wrapper, Offset at) {
  for (RenderObject node = match; !identical(node, wrapper);) {
    final parent = node.parent;
    if (parent == null) return false;
    if (parent is RenderOffstage && parent.offstage) return false;
    if (parent is RenderBox && parent.hasSize) {
      final clip = parent.describeApproximatePaintClip(node);
      if (clip != null && !clip.contains(parent.globalToLocal(at))) {
        return false;
      }
    }
    node = parent;
  }
  return true;
}

enum _Press { taken, onItsWrapper, refused }

_Press _pressOn(RenderObject match, Offset at) {
  if (!insideTheWindow(at)) return _Press.refused;
  final path = _hitAt(at);
  final takesTaps = _takesTapsBelow(_rootOverlay());
  final own = _handlerFrom(match, takesTaps);
  if (own == null) {
    final first = path.firstOrNull;
    return first != null && first is! RenderView && _within(first, match)
        ? _Press.taken
        : _Press.refused;
  }
  final first = path.where(takesTaps).firstOrNull;
  if (first == null) return _Press.refused;
  if (identical(first, own) || _within(first, match)) return _Press.taken;
  final wrapper = _handlerFrom(own.parent, takesTaps);
  return wrapper != null &&
          identical(first, wrapper) &&
          _drawnAt(match, wrapper, at)
      ? _Press.onItsWrapper
      : _Press.refused;
}

bool takesTheTap(RenderObject match, Offset at) =>
    _pressOn(match, at) == _Press.taken;

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
  if (!insideTheWindow(at)) {
    return 'off screen, at (${at.dx.round()}, ${at.dy.round()})';
  }
  final path = _hitAt(at);
  final handler = path.where(_takesTapsBelow(_rootOverlay())).firstOrNull;
  if (handler != null) return 'the tap goes to ${_named(handler)}';
  final first = path.firstOrNull;
  return first == null || first is RenderView
      ? 'nothing there takes the tap'
      : 'the tap reaches ${_named(first)}, which takes no taps';
}

String ordinal(int n) => switch (n % 100) {
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
  bool disabled = false,
  void Function(String)? note,
}) {
  final found = matchesInTree(test);
  final presses = [for (final match in found) _pressOn(match.box, match.at)];
  final wanted = disabled ? _Press.onItsWrapper : _Press.taken;
  final tappable = [
    for (final (index, press) in presses.indexed)
      if (press == wanted) index,
  ];
  final untapped = [
    for (final (index, press) in presses.indexed)
      if (press != wanted) index,
  ];
  if (tappable.length > nth) {
    final index = tappable[nth];
    if (index != nth) {
      note?.call('TAP $what: the ${ordinal(nth + 1)} match that can be '
          'tapped is the ${ordinal(index + 1)} of ${found.length} in the '
          'tree; ${untapped.length} cannot be tapped, the first because '
          '${whyNotTapped(found[untapped.first].at)}');
    }
    return found[index].at;
  }
  if (found.isEmpty) {
    throw StateError('$what: found 0, asked for the ${ordinal(nth + 1)}');
  }
  final asked = ', asked for the ${ordinal(nth + 1)}';
  if (untapped.isEmpty) {
    throw StateError('$what: found ${found.length}, all can be tapped$asked');
  }
  final can = tappable.isEmpty ? 'none' : '${tappable.length}';
  if (disabled) {
    final enabled = presses.indexOf(_Press.taken);
    if (enabled >= 0) {
      throw StateError('$what: found ${found.length}, $can disabled$asked; '
          'the ${ordinal(enabled + 1)} is not disabled: its own handler '
          'takes the press');
    }
    throw StateError('$what: found ${found.length}, $can disabled$asked; '
        'the first that cannot be pressed: '
        '${whyNotTapped(found[untapped.first].at)}');
  }
  final hint = presses[untapped.first] == _Press.onItsWrapper
      ? '; if the control is meant to be disabled, add "disabled": true'
      : '';
  throw StateError('$what: found ${found.length}, $can can be tapped$asked; '
      'the first that cannot: ${whyNotTapped(found[untapped.first].at)}$hint');
}

List<Offset> clickableCentersOf(bool Function(Widget) test) => [
      for (final match in matchesInTree(test))
        if (takesTheTap(match.box, match.at)) match.at,
    ];

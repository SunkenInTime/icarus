import 'package:flutter/widgets.dart';
import 'package:icarus/services/debug_breadcrumbs.dart';

/// Starts writing the app-wide steps to [DebugBreadcrumbs]: which widget
/// has keyboard focus, and the window going to the background and back.
/// Call once, after the binding exists.
void watchForDebugBreadcrumbs() {
  FocusNode? lastFocus;
  FocusManager.instance.addListener(() {
    final focus = FocusManager.instance.primaryFocus;
    if (identical(focus, lastFocus)) return;
    lastFocus = focus;
    DebugBreadcrumbs.add('focus', describeFocus(focus));
  });

  AppLifecycleListener(
    onStateChange: (state) => DebugBreadcrumbs.add('window', state.name),
  );
}

/// Which focus [node] is, without anything typed in it: the kind of
/// field or widget, where it sits on screen, and the kind of route it is
/// on (a page or a dialog). The names right around a focus are Flutter's
/// own, the same for every field, so this looks further up for the field
/// widget and says where it is instead.
@visibleForTesting
String describeFocus(FocusNode? node) {
  final context = node?.context;
  if (node == null || context == null || !context.mounted) return 'nothing';

  String? kind;
  var nearestNamed = _nameOf(context.widget);
  context.visitAncestorElements((element) {
    final name = _nameOf(element.widget);
    if (_fields.contains(name) || name.startsWith('ShadInput')) {
      kind = name;
      return false;
    }
    if (name == 'EditableText') kind ??= name;
    if (_plumbing.contains(nearestNamed) || nearestNamed.startsWith('_')) {
      nearestNamed = name;
    }
    return true;
  });

  final rect = node.rect;
  final route = ModalRoute.of(context);
  return [
    kind ?? nearestNamed,
    'at ${rect.left.round()},${rect.top.round()} '
        '${rect.width.round()}x${rect.height.round()}',
    if (route != null) 'on ${_nameOf(route)}',
  ].join(' ');
}

String _nameOf(Object object) => object.runtimeType.toString().split('<').first;

/// The widgets a text field is built from, nearest first, that name its
/// kind.
const _fields = {'TextField', 'TextFormField', 'CupertinoTextField'};

/// Widgets around nearly every focus that say nothing about which one it
/// is.
const _plumbing = {
  'Focus',
  'FocusScope',
  'FocusTraversalGroup',
  'Semantics',
  'MergeSemantics',
  'Actions',
  'Shortcuts',
  'CallbackShortcuts',
  'Listener',
  'MouseRegion',
  'GestureDetector',
  'RawGestureDetector',
  'TapRegion',
  'TextFieldTapRegion',
  'Builder',
  'KeyedSubtree',
  'UndoHistory',
};

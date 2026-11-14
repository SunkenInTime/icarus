import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_links.dart';

/// How a reader who can't touch placed items opens a link in a text box: by
/// clicking it, or tapping it on a touch screen. Nothing else answers a
/// reader's click on a text box, so no key has to be held as it does for
/// someone who can edit. It sits under the lineups, which keep their taps,
/// and takes nothing from anything below.
class TextLinkReadRegion extends StatefulWidget {
  const TextLinkReadRegion({required this.items, super.key});

  /// The placed items, which take no pointer from a reader.
  final GlobalKey items;

  @override
  State<TextLinkReadRegion> createState() => _TextLinkReadRegionState();
}

class _TextLinkReadRegionState extends State<TextLinkReadRegion> {
  bool _onLink = false;

  /// The press that could still be a click on [link], and where it went
  /// down.
  ({int pointer, Offset at, Uri link})? _press;

  /// The pointers held down. Once a second one joins, it's a pinch, and
  /// nothing is a click again until every one of them is up.
  final _down = <int>{};
  bool _pinch = false;

  void _release(int pointer) {
    _down.remove(pointer);
    if (_down.isEmpty) _pinch = false;
  }

  Uri? _linkAt(Offset position) {
    final items = widget.items.currentContext?.findRenderObject();
    return items is RenderBox ? textLinkAt(items, position) : null;
  }

  void _setOnLink(bool value) {
    if (value != _onLink) setState(() => _onLink = value);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      opaque: false,
      hitTestBehavior: HitTestBehavior.translucent,
      cursor: _onLink ? SystemMouseCursors.click : MouseCursor.defer,
      onHover: (event) => _setOnLink(_linkAt(event.position) != null),
      onExit: (_) => _setOnLink(false),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) {
          _down.add(event.pointer);
          _press = null;
          if (_down.length > 1) _pinch = true;
          // Another mouse button isn't a click on a link.
          if (_pinch || event.buttons != kPrimaryButton) return;
          final link = _linkAt(event.position);
          if (link != null) {
            _press = (pointer: event.pointer, at: event.position, link: link);
          }
        },
        // A press that wanders is a drag, even if it comes back.
        onPointerMove: (event) {
          final press = _press;
          if (press != null &&
              press.pointer == event.pointer &&
              (event.position - press.at).distance > kTouchSlop) {
            _press = null;
          }
        },
        onPointerCancel: (event) {
          _press = null;
          _release(event.pointer);
        },
        onPointerUp: (event) {
          final press = _press;
          _press = null;
          _release(event.pointer);
          if (press == null ||
              press.pointer != event.pointer ||
              _linkAt(event.position) != press.link) {
            return;
          }
          unawaited(openTextLink(press.link));
        },
        child: const SizedBox.expand(),
      ),
    );
  }
}

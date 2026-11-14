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

  /// The press that could still be a click, and where it went down.
  ({int pointer, Offset at})? _press;

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
        // A second finger makes it a pinch, and another mouse button isn't a
        // click on a link.
        onPointerDown: (event) => _press =
            _press == null && event.buttons == kPrimaryButton
                ? (pointer: event.pointer, at: event.position)
                : null,
        onPointerCancel: (_) => _press = null,
        onPointerUp: (event) {
          final press = _press;
          _press = null;
          if (press == null ||
              press.pointer != event.pointer ||
              (event.position - press.at).distance > kTouchSlop) {
            return;
          }
          final link = _linkAt(press.at);
          if (link != null) unawaited(openTextLink(link));
        },
        child: const SizedBox.expand(),
      ),
    );
  }
}

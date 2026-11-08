# desktop_drop (vendored)

Vendored into Icarus from
[desktop_drop 0.6.1](https://github.com/MixinNetwork/flutter-plugins/tree/main/packages/desktop_drop)
(Apache 2.0, see `LICENSE`). Everything except `example/` is copied as
published; the one change is marked `ICARUS PATCH`.

## Why this is vendored

On macOS the plugin covers the Flutter view with a plain `NSView` that
receives file drags. That view won AppKit's hit test, so AppKit treated it as
the view under the mouse instead of the Flutter view. The Flutter view's
`cursorUpdate:` is what puts Flutter's cursor back when AppKit re-checks the
cursor, and it never ran: hovering a button showed the hand for a moment and
then the arrow while the pointer was still on it. The patch makes the view
return `nil` from `hitTest(_:)`, so the Flutter view is under the mouse again.
Drags still reach the view through `registerForDraggedTypes`.

Published desktop_drop 0.9.0 has the same override. It grew out of
MixinNetwork/flutter-plugins#436, which first did this only outside a drag.
But 0.9 needs Flutter 3.47.7 and changes the Dart API. Remove this copy when
Icarus moves to desktop_drop 0.9 or later.

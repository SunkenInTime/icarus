# desktop_drop (vendored)

Vendored into Icarus from
[desktop_drop 0.6.1](https://github.com/MixinNetwork/flutter-plugins/tree/main/packages/desktop_drop)
(Apache 2.0, see `LICENSE`). Everything except `example/` is copied as
published; the one change is marked `ICARUS PATCH`.

## Why this is vendored

On macOS the plugin covers the Flutter view with a plain `NSView` that
receives file drags. That view answered AppKit's hit test, so AppKit asked it,
not the Flutter view, for the cursor, and it answered with the arrow. Hovering
a button showed the hand for a moment and then the arrow while the pointer was
still on it. The patch makes the view return `nil` from `hitTest(_:)`, so the
Flutter view stays under the mouse and keeps its cursor. Drags still reach the
view because AppKit finds drag destinations through `registerForDraggedTypes`.

Upstream made the same change in 0.9.0 (MixinNetwork/flutter-plugins#436), but
0.9 needs Flutter 3.47.7 and changes the Dart API. Remove this copy when Icarus
moves to desktop_drop 0.9 or later.

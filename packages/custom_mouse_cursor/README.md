# custom_mouse_cursor (vendored)

Custom system mouse cursors for Flutter, vendored into Icarus from
[custom_mouse_cursor 1.1.3](https://github.com/timmaffett/custom_mouse_cursor)
(Apache 2.0 — see `LICENSE`).

## Why this is vendored

Upstream is dormant and rendered all macOS cursors at 1.0 DPR ("for now we
just have to deal with pixelated cursors on mac"), which made every cursor
blurry on Retina displays. It also rasterized icon glyphs directly at their
final tiny size, which looks jagged on all platforms. Our patches (marked
`ICARUS PATCH` in the source):

1. macOS renders at the real devicePixelRatio; the Swift plugin accepts a
   `scale` argument and sets the NSImage *point* size so AppKit treats the
   bitmap as high-DPI.
2. Icon glyphs are rasterized at 4x and downscaled with high-quality
   filtering for smooth edges at any DPR.
3. Assorted correctness fixes: `exactAsset()` forwards `package`, asset loads
   honor the caller-supplied bundle, DPR updates await platform registration,
   and `registerCursor()` validates `scale` and throws a descriptive error on
   native failure.
4. Linux platform support removed — Icarus ships Windows and macOS only.
   Restore from upstream if ever needed.

Remove this vendored copy if upstream ever ships equivalent fixes.

## Supported platforms

Windows (via Flutter's built-in engine cursor channel), macOS (via the
bundled Swift plugin), and web.

## Usage

Create a `CustomMouseCursor` and use it anywhere a `MouseCursor` is accepted,
such as `MouseRegion.cursor`:

```dart
// From any Flutter icon glyph:
final cursor = await CustomMouseCursor.icon(
  Icons.rotate_right_rounded,
  size: 24,
  hotX: 12,
  hotY: 12,
  color: Colors.white,
);

// From an image asset (provide 2x/3x variants for high-DPI displays):
final assetCursor = await CustomMouseCursor.asset(
  'assets/cursors/pen.png',
  hotX: 2,
  hotY: 2,
);

MouseRegion(cursor: cursor, child: ...)
```

Cursors are devicePixelRatio-aware: they re-render automatically when the
window moves between monitors with different scale factors.

In Icarus, cursors are created in `lib/main.dart` and
`lib/const/app_cursors.dart` after the binding is initialized.

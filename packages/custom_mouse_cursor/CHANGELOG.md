## 1.1.3+icarus.1 (vendored)

Vendored into Icarus with local patches:

- macOS cursors render at the real devicePixelRatio. The Dart side no longer
  clamps macOS to 1.0 DPR, passes a `scale` argument over the channel, and the
  Swift plugin sets the NSImage point size so Retina displays get
  full-resolution cursors.
- Icon glyphs are rasterized at 4x and downscaled with high-quality filtering
  for smooth edges at any DPR.
- `exactAsset()` forwards `package`; asset loads honor the caller-supplied
  bundle; DPR updates await platform registration; `registerCursor()` throws a
  descriptive error on native failure and validates `scale`.
- Linux platform support removed: Icarus ships Windows and macOS only.
  Restore from upstream if ever needed.


# Changelog for custom_mouse_cursor package

## 1.1.3

* Update chalkdart version for pubspec.yaml
* Style clean up `if(_Logger.logging)` checks to use open/close blocks `if(_Logger.logging){}`
* Update mouse_tracker_test_utils.dart to new flutter api
* Updated example to MaterialSymbolsIcons `Symbols` class instead of deprecated MaterialSymbolsSharp

## 1.1.2

* Update README.md

## 1.1.1

* Fix generateUniqueKey() to use DateTime.now().microsecond as random seed instead of millisecond and keep
  the Random() generator around so the reuse it and the seed time being the same will never be an issue.

## 1.1.0

* Fix exactAsset dpr 1->2 bug

## 1.0.3

* Fix onMetricsChange() callback to chain to previous set callback.
* Cleanup logging and enable const setting to eliminate entirely.
* Made imageBuffer non-nullable and always present in cache.

## 1.0.2

* Clean up readme and example.

## 1.0.1

* Add Flutter engine [PR#41186](https://github.com/flutter/engine/pull/41186) to README.md

## 1.0.0

* Initial release

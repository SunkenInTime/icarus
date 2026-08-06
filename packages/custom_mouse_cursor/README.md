> **Vendored into Icarus** from custom_mouse_cursor 1.1.3 (Apache 2.0,
> https://github.com/timmaffett/custom_mouse_cursor). Upstream renders all
> macOS cursors at 1.0 DPR ("for now we just have to deal with pixelated
> cursors on mac"), which made every cursor blurry on Retina displays, and
> rasterizes icon glyphs directly at their final tiny size, which looks
> jagged on all platforms. Our patches (marked `ICARUS PATCH`):
>
> 1. macOS renders at the real devicePixelRatio; the Swift plugin accepts a
>    `scale` argument and sets the NSImage *point* size so AppKit treats the
>    bitmap as high-DPI.
> 2. Icon glyphs are rasterized at 4x and downscaled with high-quality
>    filtering for smooth edges at any DPR.
>
> Remove this vendored copy if upstream ever ships equivalent fixes.

# custom_mouse_cursor

![](https://img.shields.io/pub/v/custom_mouse_cursor?color=green)
![Publisher: hiveright.tech](https://img.shields.io/pub/publisher/custom_mouse_cursor)
[![Apache 2.0 License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](/LICENSE)

This package provides custom system mouse cursor support for Flutter.  The custom mouse cursors are native system cursors which are devicePixelRatio aware so they will remanin the proper size on different devicePixelRatio's and on machines with multiple monitors with varying devicePixelRatios.  Simply create [CustomMouseCursor]()'s objects and use them in the same way you would use [SystemMouseCursors](). 

They are trivial to create from any flutter icon or from image assets.

```dart
  // from image
  myCustomCursor = await CustomMouseCursor.asset('myCursorImage.png',  hotX:2, hotY:2 );
  // from icon
  iconCursor = await CustomMouseCursor.icon( Icons.redo, size: 24, hotX: 22, hotY: 17 );
```

## A LIVE flutter web example can be found [here](https://timmaffett.github.io/custom_mouse_cursor/)
### (at https://timmaffett.github.io/custom_mouse_cursor/ )

The [live example](https://timmaffett.github.io/custom_mouse_cursor/) was been compiled with a local version of the engine with [PR#41186](https://github.com/flutter/engine/pull/41186).

<img src="https://raw.githubusercontent.com/timmaffett/custom_mouse_cursor/master/media/example_app_windowcapture_01.png" width="100%">

CustomMouseCursor's can be created directly from any flutter image asset as well as flutter icons (just as you would with Flutter Icon).
For power users Flutter's ui.Image objects can also be used (allowing for anything you might dream up, even animated cursor's).

CustomMouseCursors are very performant.  All work is cached so switching between monitors of varying devicePixelRatio's is seemless.

The custom mouse cursors will be automatically adjusted for the system's devicePixelRatio and when moving the flutter window between monitors with varying devicePixelRatios.

### Note

Currently the flutter master channel is required for windows support. (Window's support is not possible without [changes to the flutter engine](https://github.com/flutter/engine/pull/36143) that are included within the master channel.)

This package provides platform plugins that provide support for macos and limux platforms on both the stable and master flutter channels.

I have submitted [flutter engine PR#41186](https://github.com/flutter/engine/pull/41186) that provides support for the web platform.  With luck that PR will land in the master channel soon.

## Supported Platforms

- [x] macOS (works with current flutter `stable` channel or `master`)
- [x] Linux (works with current flutter `stable` channel or `master`)
- [x] Windows (works with current flutter `stable` channel or `master`)
- [x] Web (requires flutter engine [PR#41186](https://github.com/flutter/engine/pull/41186), hopefully `master` channel soon)*

* ~~As of 4/9/23 Windows support requires the master channel (until [flutter engine PR#36143](https://github.com/flutter/engine/pull/36143) lands in stable).~~ Windows support is now available on all channels.

* As of 5/27/24 Web support requires custom engine with [flutter engine PR#41186](https://github.com/flutter/engine/pull/41186) lands in the master channel.  [Unfortunately I have not had time to address change requests for this PR and it is still lingering.  File an issue on github for this repo if you really need web support and it will motivate me to spend the time required to address this.]

This package could not exist without the work of @Kingtous's [flutter engine PR#36143](https://github.com/flutter/engine/pull/36143) allowing proper windows support and @imiskolee's github for original the [Windows, Mac and linux support](https://github.com/imiskolee/flutter_custom_cursor).


~~Note: Currently, the api required by this plugin on Windows is included in flutter `master` branch. It means that u need to use this plugin with flutter master branch on Windows platform. See [flutter engine PR#36143](https://github.com/flutter/engine/pull/36143) for details.~~ Windows support is now available on all channels.

## Example use
Each example shows excerpt from example app with the the cursor the example code created showing on the left side of the image.
The `CustomMouseCursor` cursor objects are used exactly as you would any `SystemMouseCursors.xxxx` cursor.
Custom mouse cursors are can be created from asset images or icons.

`CustomMouseCursor.asset()` and `CustomMouseCursor.exactasset()` are used to create custom cursors from asset images.
`CustomMouseCursor.icon()` is used to create custom cursor from any IconData object (just as you would a regular `Icon` widget in flutter).

<img src="https://raw.githubusercontent.com/timmaffett/custom_mouse_cursor/master/media/example_cursor1.png" width="100%">

```DART
  // Example of image asset that has many device pixel ratio versions (1.5x,2.0x,2.5x,3.0x,3.5x,4.0x,8.0x).
  // The exact size required for most DevicePixelRatio will be able to be loaded directly and used
  // without scaling. 
  assetCursor = await CustomMouseCursor.asset(
      "assets/cursors/startrek_mousepointer.png",
      hotX: 18,
      hotY: 0);
```

<img src="https://raw.githubusercontent.com/timmaffett/custom_mouse_cursor/master/media/example_cursor2.png" width="100%">

```dart
  // Example of image asset that has only device pixel ratio versions (1.0x ands 2.5x).
  // In this case if the devicePixelRatio was 2.0x the 2.5x asset would be loaded and
  // scaled down to 2.0x size.
  assetCursorOnly25 = await CustomMouseCursor.asset(
      "assets/cursors/startrek_mousepointer25Only.png",
      hotX: 18,
      hotY: 0);

```

<img src="https://raw.githubusercontent.com/timmaffett/custom_mouse_cursor/master/media/example_cursor3.png" width="100%">

```dart
  // Example of image asset only at 8x native DevicePixelRatio so will get scaled down
  // to most/all encoutered DPR's.
  assetCursorNative8x = await CustomMouseCursor.exactAsset(
      "assets/cursors/star-trek-mouse-pointer-cursor292x512.png",
      hotX: 144,
      hotY: 0,
      nativeDevicePixelRatio: 8.0);
```

<img src="https://raw.githubusercontent.com/timmaffett/custom_mouse_cursor/master/media/example_cursor4.png" width="100%">

```dart
  // Example of a custom cursor created from a icon, with drop shadow added.
  List<Shadow> shadows = [
    const BoxShadow(
      color: Color.fromRGBO(0, 0, 0, 0.8),
      offset: Offset(4, 3),
      blurRadius: 3,
      spreadRadius: 2,
    ),
  ];
  iconCursor = await CustomMouseCursor.icon(
      Icons.redo,
      size: 24,
      hotX: 22,
      hotY: 17,
      color: Colors.pinkAccent,
      shadows: shadows);
```

<img src="https://raw.githubusercontent.com/timmaffett/custom_mouse_cursor/master/media/example_cursor5.png" width="100%">

```dart
  // example of custom cursor created from a icon that is filled, colored blue and
  // added drop shadow.
  msIconCursor = await CustomMouseCursor.icon(
      MaterialSymbols.arrow_selector_tool,
      size: 32,
      hotX: 8,
      hotY: 2,
      fill: 1,
      color: Colors.blueAccent,
      shadows: shadows);
```

<img src="https://raw.githubusercontent.com/timmaffett/custom_mouse_cursor/master/media/example_cursor6.png" width="100%">

```DART
  // another exactAsset example where the supplied image asset is a 2.0x image.  This will
  // be scaled down at 1.0x devicePixelRatios and scaled up for >2.0x device pixel ratios.
  assetCursorSingleSize = await CustomMouseCursor.exactAsset(
      "assets/cursors/example_game_cursor_64x64.png",
      hotX: 2,
      hotY: 2,
      nativeDevicePixelRatio: 2.0);
```

<img src="https://raw.githubusercontent.com/timmaffett/custom_mouse_cursor/master/media/example_cursor7.png" width="100%">

```
  // Here we create a ui.Image from loading raw bytes from rootBundle.load(), but this
  // could be a ui.Image created any way, from drawing to the canvas, etc.
  final rawBytes = await rootBundle.load("assets/cursors/cat_cursor.png");
  final rawUintList = rawBytes.buffer.asUint8List();
  final ui.Image catCursor_uiImage = await decodeImageFromList(rawUintList);

  // another exactAsset example where the supplied image asset is a 2.0x image.  This will
  // be scaled down at 1.0x devicePixelRatios and scaled up for >2.0x device pixel ratios.
  catUiImageCursor = await CustomMouseCursor.image(
      catCursor_uiImage,
      hotX: 2,
      hotY: 2,
      thisImagesDevicePixelRatio: 2.0);
    
  // you could add additional images for different devicePixelRatios with 
  // catUiImageCursor.addImage(..) 
```

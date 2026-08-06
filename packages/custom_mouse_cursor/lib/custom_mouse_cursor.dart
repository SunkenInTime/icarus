// ignore_for_file: dead_code, curly_braces_in_flow_control_structures

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:chalkdart/chalk.dart';

class _Logger {
  static const logging = false; // set to false for release
  static const hookLogging = false; // set to false for release
  static void log(String message) {
    debugPrint(message);
  }
}

/// The [CustomMouseCursor] class allows the user to create custom system mouse cursors from various
/// sources.  See [MouseCursor] for more information on using cursors within flutter.
/// [CustomMouseCursor] cursor objects can be used just as you would any [SystemMouseCursor] built in cursor
/// from [SystemMouseCursors].
///
/// ## Using cursors
///
/// A [CustomMouseCursor] object is used by being assigned to a [MouseRegion] or
/// another widget that exposes the [MouseRegion] API, such as
/// [InkResponse.mouseCursor].  This is behavior is identical for any [MouseCursor]
/// subclass.
///
/// The [asset] and [exactasset] static methods can be use to create custom cursors from flutter
/// assets.
///
/// The [icon] static method can be used to create custom cursors from any flutter [IconData].
///
/// The [image] static method can be used to create icon's from [ui.Image] objects.
/// The image will be scaled to create cursors for any other encounted devicePixelRatop.
/// The image is supplied with it's native devicePixelRatio.  The image should have a devicePixelRatio
/// large enough that it is scaled down for most encountered devicePixelRatios. (at least 2.0 typically).
///
//ignore: must_be_immutable
class CustomMouseCursor extends MouseCursor {
  /// This is the cursor's key - it is *actually* final for all platforms EXCEPT web,
  /// where it can change on DPI resolution changes because on the web platform this
  /// *IS* the cursor definition (as a CSS cursor data-uri image)
  String _key;

  String get key => _key;

  set key(String newKey) {
    if (!kIsWeb) {
      throw ('Attempt to change the key on a CustomMouseCursor when the platform is not web!');
    }
    _key = newKey;
  }

  /// The origin story for this cursor, whether it was created from an exact asset,
  /// a DPI aware AssetImage, an icon or an image.  This is used to decide how to
  /// RE-create the cursor when the DPI/DevicePixelRatio changes.
  /// If [originStory]==[CustomMouseCursorCreationType.asset] then [_assetBundleImageProvider]
  /// contains the [AssetImage] used in its creation (and used for updating on DevicePixelRatio changes).
  /// If [originStory]==[CustomMouseCursorCreationType.exactasset] then [_assetBundleImageProvider]
  /// contains the [ExactAssetImage] used in its creation (and used for updating on DevicePixelRatio changes).
  /// If [originStory]==[CustomMouseCursorCreationType.icon] then [_iconCreationInfo] will hold
  /// information on how to regenerate the icon cursor on DevicePixelRatio changes.
  /// If [originStory]==[CustomMouseCursorCreationType.image] then there will be
  /// no automatic handling of the cursore for DevicePixelRatio changes.
  final CustomMouseCursorCreationType originStory;

  /// When the DevicePixelRatio is different or changes from this size
  /// the the pointer will be scaled accordingly when
  /// CustomMousePointer.didChangeDependencies() is called.
  /// The user should always call CustomMousePointer.didChangeDependencies() from
  /// their top level widget's didChangeDependencies() handler to
  /// ensure that pointers change to DPI/DevicePixelRatio dependent sizes.
  ///
  /// For example if you were specifying a size of 32 for the icon, and the
  /// DevicePixelRatio changed to 2.0, the icon would be scaled
  /// by ratio=newDevicePixelRatio/nativeDevicePixelRatio=2.0 and
  /// the icon would be scaled up to newSize=2.0x32=64 pixels.
  /// This is the DevicePixelRatio for which the
  /// [hotXAtNativeDevicePixelRatio] and [hotYAtNativeDevicePixelRatio]
  /// are specified.
  final double nativeDevicePixelRatio;

  /// This is the X location of hot spot at the [nativeDevicePixelRatio]
  /// This gets scaled accordingly on DPI changes.
  final int hotXAtNativeDevicePixelRatio;

  /// This is the Y location of hot spot at the [nativeDevicePixelRatio]
  /// This gets scaled accordingly on DPI changes.
  final int hotYAtNativeDevicePixelRatio;

  /// The DevicePixelRatio for which the current backing cursor was created.
  /// This applys only to desktop native platforms (windows, macOS, and linux).
  /// On web systems the [key] holds a cursor definition that includes support for all
  /// encountered DevicePixelRatios - and this will simply hold the device pixel ratio
  /// that was last encountered.
  double currentCursorDevicePixelRatio;

  /// If [originStory]==[CustomMouseCursorCreationType.asset] then this contains the
  /// [AssetImage] used in its created (and used for updating on DevicePixelRatio changes).
  /// If [originStory]==[CustomMouseCursorCreationType.exactasset] then this contains the
  /// [ExactAssetImage] used in its created (and used for updating on DevicePixelRatio changes).
  AssetBundleImageProvider? _assetBundleImageProvider;

  /// This was exactAssetDevicePixelRatio passed to exactasset() - otherwise it will match
  /// nativeDevicePixelRatio.
  double? _exactAssetDevicePixelRatio;

  _CustomMouseCursorFromIconOriginInfo? _iconCreationInfo;

  /// This holds cache of the bitmaps/info we have made for this bitmap for different
  /// DevicePixelRatio monitors.
  final Map<double, _CustomMouseCursorDPRBitmapCache> _dprBitmapCache = {};

  /// Cache of all the created custom cursors
  static final Map<String, CustomMouseCursor> _cursorCacheOfAllCreatedCursors =
      {};

  CustomMouseCursor._(
      this._key,
      this.originStory,
      this.nativeDevicePixelRatio,
      this.hotXAtNativeDevicePixelRatio,
      this.hotYAtNativeDevicePixelRatio,
      this.currentCursorDevicePixelRatio)
      : assert(_key != "");

  /// Creates a cursor with the image obtained from an exact asset
  /// bundle. The key for the image is given by the [assetName] argument.
  /// Using this method allows the pixel-density-aware asset resolution to be avoided.
  ///
  /// This method works the same as [asset] but allows the user to specify
  /// the *exact* image resource that they would like to load.  This bypasses
  /// the considerstion of devicePixelRatio when loading the image and instead
  /// loads the exact asset resource specified by the [assetName].
  /// (Internally this is implemented with a call to [asset] with the [useExactAssetImage]
  /// argument set to true).
  ///
  /// The [package] argument must be non-null when displaying an image from a
  /// package and null otherwise. See the `Assets in packages` section for
  /// details.
  ///
  /// If the [bundle] argument is omitted or null, then the
  /// [DefaultAssetBundle] will be used.
  ///
  /// ## Assets in packages
  ///
  /// To create the widget with an asset from a package, the [package] argument
  /// must be provided. For instance, suppose a package called `my_icons` has
  /// `icons/heart.png` .
  ///
  /// {@tool snippet}
  /// Then to display the image, use:
  ///
  /// ```dart
  /// Image.asset('icons/heart.png', package: 'my_icons')
  /// ```
  /// {@end-tool}
  ///
  /// Assets used by the package itself should also be displayed using the
  /// [package] argument as above.
  ///
  /// If the desired asset is specified in the `pubspec.yaml` of the package, it
  /// is bundled automatically with the app. In particular, assets used by the
  /// package itself must be specified in its `pubspec.yaml`.
  ///
  /// A package can also choose to have assets in its 'lib/' folder that are not
  /// specified in its `pubspec.yaml`. In this case for those images to be
  /// bundled, the app has to specify which ones to include. For instance a
  /// package named `fancy_backgrounds` could have:
  ///
  ///     lib/backgrounds/background1.png
  ///     lib/backgrounds/background2.png
  ///     lib/backgrounds/background3.png
  ///
  /// To include, say the first image, the `pubspec.yaml` of the app should
  /// specify it in the assets section:
  ///
  /// ```yaml
  ///   assets:
  ///     - packages/fancy_backgrounds/backgrounds/background1.png
  /// ```
  ///
  /// The `lib/` is implied, so it should not be included in the asset path.
  ///
  /// See also:
  ///
  ///  * [ExactAssetImage], (this is used with a scale=1.0 for loading the image asset).
  ///  * <https://flutter.dev/assets-and-images/>, an introduction to assets in
  ///    Flutter.
  static Future<CustomMouseCursor> exactAsset(
    String assetName, {
    int hotX = 0,
    int hotY = 0,
    double nativeDevicePixelRatio = 1.0,

    /// An existing cursor that should be updated instead of creating a new cursor.
    /// This is used on DevicePixelRatio changes to update the cursors backing
    /// image.
    CustomMouseCursor? existingCursorToUpdate,

    /// Optionally allow caller to send BuildContext to use to get a ImageConfiguration (if needed)
    BuildContext? context,

    /// This argument is passed to [ExactAssetImage]. If the `bundle` argument is omitted or null, then the
    /// [DefaultAssetBundle] will be used.
    AssetBundle? bundle,

    /// This argument is passed to [ExactAssetImage]. Assets used by the package itself should also be displayed using the
    /// [package] argument as above.
    String? package,
  }) async {
    return asset(assetName,
        hotX: hotX,
        hotY: hotY,
        nativeDevicePixelRatio: nativeDevicePixelRatio,
        existingCursorToUpdate: existingCursorToUpdate,
        context: context,
        bundle: bundle,
        package: package,
        useExactAssetImage: true);
  }

  /// Creates a cursor with the image obtained from an asset
  /// bundle. The key for the image is given by the [assetName] argument.
  ///
  /// The [package] argument must be non-null when displaying an image from a
  /// package and null otherwise. See the `Assets in packages` section for
  /// details.
  ///
  /// If the [bundle] argument is omitted or null, then the
  /// [DefaultAssetBundle] will be used.
  ///
  /// By default, the pixel-density-aware asset resolution will be attempted. In
  /// addition:
  ///
  /// {@tool snippet}
  ///
  /// Suppose that the project's `pubspec.yaml` file contains the following:
  ///
  /// ```yaml
  /// flutter:
  ///   assets:
  ///     - images/cat.png
  ///     - images/2x/cat.png
  ///     - images/3.5x/cat.png
  /// ```
  /// {@end-tool}
  ///
  /// On a screen with a device pixel ratio of 2.0, the following widget would
  /// render the `images/2x/cat.png` file:
  ///
  /// ```dart
  /// Image.asset('images/cat.png')
  /// ```
  ///
  /// This corresponds to the file that is in the project's `images/2x/`
  /// directory with the name `cat.png` (the paths are relative to the
  /// `pubspec.yaml` file).
  ///
  /// On a device with a 4.0 device pixel ratio, the `images/3.5x/cat.png` asset
  /// would be used. On a device with a 1.0 device pixel ratio, the
  /// `images/cat.png` resource would be used.
  ///
  /// The `images/cat.png` image can be omitted from disk (though it must still
  /// be present in the manifest). If it is omitted, then on a device with a 1.0
  /// device pixel ratio, the `images/2x/cat.png` image would be used instead.
  ///
  ///
  /// ## Assets in packages
  ///
  /// To create the widget with an asset from a package, the [package] argument
  /// must be provided. For instance, suppose a package called `my_icons` has
  /// `icons/heart.png` .
  ///
  /// {@tool snippet}
  /// Then to display the image, use:
  ///
  /// ```dart
  /// Image.asset('icons/heart.png', package: 'my_icons')
  /// ```
  /// {@end-tool}
  ///
  /// Assets used by the package itself should also be displayed using the
  /// [package] argument as above.
  ///
  /// If the desired asset is specified in the `pubspec.yaml` of the package, it
  /// is bundled automatically with the app. In particular, assets used by the
  /// package itself must be specified in its `pubspec.yaml`.
  ///
  /// A package can also choose to have assets in its 'lib/' folder that are not
  /// specified in its `pubspec.yaml`. In this case for those images to be
  /// bundled, the app has to specify which ones to include. For instance a
  /// package named `fancy_backgrounds` could have:
  ///
  ///     lib/backgrounds/background1.png
  ///     lib/backgrounds/background2.png
  ///     lib/backgrounds/background3.png
  ///
  /// To include, say the first image, the `pubspec.yaml` of the app should
  /// specify it in the assets section:
  ///
  /// ```yaml
  ///   assets:
  ///     - packages/fancy_backgrounds/backgrounds/background1.png
  /// ```
  ///
  /// The `lib/` is implied, so it should not be included in the asset path.
  ///
  ///
  /// See also:
  ///
  ///  * [AssetImage], which is used to implement the behavior when the scale is
  ///    omitted.
  ///  * [ExactAssetImage], which is used to implement the behavior when the
  ///    scale is present.
  ///  * <https://flutter.dev/assets-and-images/>, an introduction to assets in
  ///    Flutter.
  static Future<CustomMouseCursor> asset(
    String assetName, {
    int hotX = 0,
    int hotY = 0,
    double nativeDevicePixelRatio = 1.0,

    /// An existing cursor that should be updated instead of creating a new cursor.
    /// This is used on DevicePixelRatio changes to update the cursors backing
    /// image.
    CustomMouseCursor? existingCursorToUpdate,

    /// Optionally allow caller to send BuildContext to use to get a ImageConfiguration (if needed)
    BuildContext? context,

    /// Optionally specify that ExactAssetImage should be used instead of AssetImage
    bool useExactAssetImage = false,

    /// This argument is passed to [AssetImage]. If the `bundle` argument is omitted or null, then the
    /// [DefaultAssetBundle] will be used.
    AssetBundle? bundle,

    /// This argument is passed to [AssetImage]. Assets used by the package itself should also be displayed using the
    /// [package] argument as above.
    String? package,
  }) async {
    double exactAssetDevicePixelRatio = nativeDevicePixelRatio;
    if (_Logger.logging) {
      _Logger.log(chalk.green(
          '\n\n${useExactAssetImage ? 'EXACT' : ''}Asset() assetName=$assetName useExactAssetImage=$useExactAssetImage nativeDevicePixelRatio=$nativeDevicePixelRatio existingCursorToUpdate=$existingCursorToUpdate'));
    }
    // If we have a ImageConfiguration object already from didChangeDependencies() being called
    // use that to use AssetImage to do a DPI aware loading of the pointer
    AssetBundleImageProvider? assetBundleImageProvider;
    AssetBundleImageKey? assetAwareKey;
    double rescaleRatioRequiredForImage = 0;
    // call and get an ImageConfiguration if we don't have one yet
    _lastImageConfiguration ??=
        _createLocalImageConfigurationWithOrWithoutContext(context: context);

    if (_lastImageConfiguration != null &&
        _lastImageConfiguration!.devicePixelRatio != null) {
      assetBundleImageProvider = useExactAssetImage
          ? ExactAssetImage(assetName, bundle: bundle, package: package)
          : AssetImage(assetName, bundle: bundle, package: package);
      assetAwareKey =
          await assetBundleImageProvider.obtainKey(_lastImageConfiguration!);
      if (_Logger.logging) {
        _Logger.log(
            '  _lastImageConfiguration returned DPR of ${_lastImageConfiguration!.devicePixelRatio} for system');
        _Logger.log(
            '  assetAwareKey was obtainKey`ed() to be ${assetAwareKey.name} scale=${assetAwareKey.scale}');
      }
      if (nativeDevicePixelRatio != 1.0 && assetAwareKey.scale == 1.0) {
        // WE were told that the 1.0 is actually [nativeDevicePixelRatio] SO USE THAT
        //  (ExactImageAsset() will always return scale of 1.0)
        rescaleRatioRequiredForImage =
            _lastImageConfiguration!.devicePixelRatio! / nativeDevicePixelRatio;
        if (_Logger.logging) {
          _Logger.log(
              '  ASSETAWAREKEY SCALE==1.0 SPECIAL CASE  nativeDevicePixelRatio=$nativeDevicePixelRatio  exactAssetDevicePixelRatio=$exactAssetDevicePixelRatio');
          _Logger.log(
              '  $nativeDevicePixelRatio was PASSED for native - but then _lastImageConfiguration!.devicePixelRatio=${_lastImageConfiguration!.devicePixelRatio} and assetAwareKey.scale=${assetAwareKey.scale}');
          _Logger.log(
              '  made  rescaleRatioRequiredForImage=$rescaleRatioRequiredForImage');
        }
      } else {
        // At this point it has chosen *SOME* scale of image to use - this MIGHT NOT BE the devicePixelRatio exactly,
        //  so we will need to scale to that..
        rescaleRatioRequiredForImage =
            _lastImageConfiguration!.devicePixelRatio! / assetAwareKey.scale;
      }

      if (_Logger.logging) {
        _Logger.log(
            '  Using lastImageConfiguration got rescaleRatioRequiredForImage=$rescaleRatioRequiredForImage  name=${assetAwareKey.name} scale=${assetAwareKey.scale}');
      }
      if (nativeDevicePixelRatio !=
          _lastImageConfiguration!.devicePixelRatio!) {
        if (_Logger.logging) {
          _Logger.log(
              '  CHANGING NATIVE PIXEL RATIO (OLD DPR=$nativeDevicePixelRatio hotX=$hotX hotY=$hotY)');
        }
        double adjustHotsToNativeDPRChange =
            _lastImageConfiguration!.devicePixelRatio! / nativeDevicePixelRatio;
        hotX = (hotX * adjustHotsToNativeDPRChange).round();
        hotY = (hotY * adjustHotsToNativeDPRChange).round();
        nativeDevicePixelRatio = _lastImageConfiguration!.devicePixelRatio!;
        if (!useExactAssetImage) {
          exactAssetDevicePixelRatio = nativeDevicePixelRatio;
        }
        if (_Logger.logging) {
          _Logger.log(
              '  UPDATED values DPR nativeDevicePixelRatio=$nativeDevicePixelRatio hotX=$hotX hotY=$hotY   exactAssetDevicePixelRatio=$exactAssetDevicePixelRatio');
        }
      }
      //
      assetName = assetAwareKey.name;
    } else {
      // THIS CASE SHOULD NEVER BE ABLE TO HAPPEN
      throw ('Unknown DevicePixelRatio in asset');
    }

    // NOW we have decide on the name we will use then check for existing cursor
    if (_cursorCacheOfAllCreatedCursors.containsKey(assetName)) {
      if (_Logger.logging)
        _Logger.log('  Found cursor in cache with assetname =$assetName');
      return _cursorCacheOfAllCreatedCursors[assetName]!;
    }

    // and load the asset from the caller-supplied bundle when given
    final rawAssetImageBytes = await (bundle ?? rootBundle).load(assetName);

    final rawUint8 = rawAssetImageBytes.buffer.asUint8List();

    final uiImage = await _createUIImageFromPNGUint8ListBufferAndPossiblyScale(
        rawUint8,
        rescaleRatioRequiredForImage: rescaleRatioRequiredForImage);

    if (_Logger.logging)
      _Logger.log(
          '  Loaded Asset image width=${uiImage.width} height=${uiImage.height}');

    final cursor = await _commonCursorImageInstaller(
        uiImage, hotX, hotY, nativeDevicePixelRatio,
        key: assetName,
        originStory: useExactAssetImage
            ? CustomMouseCursorCreationType.exactasset
            : CustomMouseCursorCreationType.asset,
        existingCursorToUpdate: existingCursorToUpdate);

    cursor._assetBundleImageProvider = assetBundleImageProvider;
    cursor._exactAssetDevicePixelRatio = exactAssetDevicePixelRatio;

    if (_Logger.logging) {
      _Logger.log(
          '  ALMOST DONE ABOUT TO CHECK _createDevicePixelRatio1xVersion IS WEB=$kIsWeb  _useURLDataURICursorCSS=$_useURLDataURICursorCSS  nativeDevicePixelRatio=$nativeDevicePixelRatio');
    }
    if (kIsWeb && _useURLDataURICursorCSS && nativeDevicePixelRatio != 1.0) {
      // For web platform when using legacy URL datauri css cursors we need to always include
      // a 1.0 DPR version of the cursor.
      await _createDevicePixelRatio1xVersion(cursor);
    }

    return cursor;
  }

  /// This is similar to asset() but for UPDATING a cursor with an additional devicePixelRatio version.
  /// If the cursor was created with asset() then AssetImage() is used to get the closest image to the
  /// requested [newDevicePixelRatio], otherwise ExactAssetImage() used and the same asset used original is
  /// used again.  The loaded image is scaled to be the exact DPR requested by [newDevicePixelRatio] if
  /// necessary.
  Future<void> _updateAssetToNewDpi(double newDevicePixelRatio) async {
    assert(
        originStory == CustomMouseCursorCreationType.asset ||
            originStory == CustomMouseCursorCreationType.exactasset,
        '_updateAssetToNewDpi() called on non asset cursor ($originStory key=$key)');
    assert(_assetBundleImageProvider != null);

    if (_Logger.logging) {
      _Logger.log(chalk.brightGreen(
          'ENTERING _updateAssetToNewDpi( newDevicePixelRatio=$newDevicePixelRatio )   nativeDevicePixelRatio=$nativeDevicePixelRatio _exactAssetDevicePixelRatio=$_exactAssetDevicePixelRatio'));
    }
    bool useExactAssetImage =
        (originStory == CustomMouseCursorCreationType.exactasset);

    late final double rescaleRatioRequiredForImage;
    // call and get an ImageConfiguration if we don't have one yet
    final forcedImageConfig =
        _createLocalImageConfigurationWithOrWithoutContext(
            forceDevicePixelRatio: newDevicePixelRatio);

    final assetAwareKey =
        await _assetBundleImageProvider!.obtainKey(forcedImageConfig);

    if (_Logger.logging) {
      _Logger.log(
          '  forcedImageConfig returned DPR of ${forcedImageConfig.devicePixelRatio} for system');
      _Logger.log(
          '  assetAwareKey was obtainKey`ed() to be ${assetAwareKey.name} scale=${assetAwareKey.scale}');
    }
    if (useExactAssetImage &&
        _exactAssetDevicePixelRatio != 1.0 &&
        assetAwareKey.scale == 1.0) {
      // During EXACTASSET were told that the 1.0 is actually [nativeDevicePixelRatio] SO USE THAT
      //  (ExactImageAsset() will always return scale of 1.0)  - so we must use the pixel
      //  ratio we were told the image representing in the call to exactAsset().
      rescaleRatioRequiredForImage =
          newDevicePixelRatio / _exactAssetDevicePixelRatio!;
      if (_Logger.logging) {
        _Logger.log(
            '  ASSETAWAREKEY SCALE==1.0 SPECIAL CASE  _exactAssetDevicePixelRatio=$_exactAssetDevicePixelRatio');
        _Logger.log(
            '  newDevicePixelRatio=$newDevicePixelRatio (orginally we were told nativeDevicePixelRatio=$nativeDevicePixelRatio) was PASSED for native - but then newDevicePixelRatio=$newDevicePixelRatio and assetAwareKey.scale=${assetAwareKey.scale}');
        _Logger.log(
            '  made  rescaleRatioRequiredForImage=$rescaleRatioRequiredForImage');
      }
    } else {
      // At this point it has chosen *SOME* scale of image to use - this MIGHT NOT BE the devicePixelRatio exactly,
      //  so we will need to scale to that..
      rescaleRatioRequiredForImage = newDevicePixelRatio / assetAwareKey.scale;
    }

    // HOT SPOTS where orginally STORED at [nativeDevicePixelRatio] DPR (which may have changed from what user
    // passed to original asset()/exactasset() call), so we must adjust them with [nativeDevicePixelRatio]
    // from there to the [newDevicePixelRatio].
    double adjustHotSpotRatio = newDevicePixelRatio / nativeDevicePixelRatio;
    double hotX = hotXAtNativeDevicePixelRatio * adjustHotSpotRatio;
    double hotY = hotYAtNativeDevicePixelRatio * adjustHotSpotRatio;

    if (_Logger.logging) {
      _Logger.log(
          '  _updateAssetToNewDpi() updating by LOADING asset ${assetAwareKey.name} scale=${assetAwareKey.scale} rescaleRatioRequiredForImage=$rescaleRatioRequiredForImage adjusted adjustHotSpotRatio=$adjustHotSpotRatio hotX=$hotX hotY=$hotY');
    }
    final rawAssetImageBytes =
        await (assetAwareKey.bundle).load(assetAwareKey.name);

    final rawUint8 = rawAssetImageBytes.buffer.asUint8List();

    final uiImage = await _createUIImageFromPNGUint8ListBufferAndPossiblyScale(
        rawUint8,
        rescaleRatioRequiredForImage: rescaleRatioRequiredForImage);

    if (_Logger.logging) {
      _Logger.log(
          '  _updateAssetToNewDpi() UPDATE Asset loaded image width=${uiImage.width} height=${uiImage.height}');
      _Logger.log(
          '  calling image() with EXISTING ASSET CURSOR newDevicePixelRatio=$newDevicePixelRatio');
    }
    await _commonCursorImageInstaller(
        uiImage, hotX.round(), hotY.round(), newDevicePixelRatio,
        key: key, originStory: originStory, existingCursorToUpdate: this);
  }

  /// Creates a custom mouse cursor with a glyph from a font described in
  /// an [IconData] such as material's predefined [IconData]s in [Icons].
  ///
  /// The size (in logical pixels) of the icon used for the cursor is specified
  /// with the [size] argument.
  /// The hot spot location (in logical pixels) is specified with the
  /// [hotX] and [hotY] arguments.
  ///
  /// The appearance of the icon can be further customized with the
  /// [color], [fill], [weight], [opticalSize] and [shadows] arguments.
  ///
  static Future<CustomMouseCursor> icon(
    /// The icon to display. The available icons are described in [Icons].
    ///
    /// The icon can be null, in which case the widget will render as an empty
    /// space of the specified [size].
    final IconData icon, {
    /// The size of the cursor to create in logical pixels.
    /// A size X size square cursor will be created.
    ///
    /// Defaults to 32.
    ///
    double size = 32,

    /// X coordinate of the cursor's hot spot.
    int hotX = 0,

    /// Y coordinate of the cursor's hot spot.
    int hotY = 0,

    /// The fill for drawing the icon.
    ///
    /// Requires the underlying icon font to support the `FILL` [FontVariation]
    /// axis, otherwise has no effect. Variable font filenames often indicate
    /// the supported axes. Must be between 0.0 (unfilled) and 1.0 (filled),
    /// inclusive.
    ///
    /// Can be used to convey a state transition for animation or interaction.
    ///
    /// Defaults to undefined.
    ///
    /// See also:
    ///  * [weight], for controlling stroke weight.
    ///  * [grade], for controlling stroke weight in a more granular way.
    ///  * [opticalSize], for controlling optical size.
    final double? fill,

    /// The stroke weight for drawing the icon.
    ///
    /// Requires the underlying icon font to support the `wght` [FontVariation]
    /// axis, otherwise has no effect. Variable font filenames often indicate
    /// the supported axes. Must be greater than 0.
    ///
    /// Defaults to undefined.
    ///
    /// See also:
    ///  * [fill], for controlling fill.
    ///  * [grade], for controlling stroke weight in a more granular way.
    ///  * [opticalSize], for controlling optical size.
    ///  * https://fonts.google.com/knowledge/glossary/weight_axis
    final double? weight,

    /// The grade (granular stroke weight) for drawing the icon.
    ///
    /// Requires the underlying icon font to support the `GRAD` [FontVariation]
    /// axis, otherwise has no effect. Variable font filenames often indicate
    /// the supported axes. Can be negative.
    ///
    /// Grade and [weight] both affect a symbol's stroke weight (thickness), but
    /// grade has a smaller impact on the size of the symbol.
    ///
    /// Grade is also available in some text fonts. One can match grade levels
    /// between text and symbols for a harmonious visual effect. For example, if
    /// the text font has a -25 grade value, the symbols can match it with a
    /// suitable value, say -25.
    ///
    /// Defaults to undefined.
    ///
    /// See also:
    ///  * [fill], for controlling fill.
    ///  * [weight], for controlling stroke weight in a less granular way.
    ///  * [opticalSize], for controlling optical size.
    ///  * https://fonts.google.com/knowledge/glossary/grade_axis
    final double? grade,

    /// The optical size for drawing the icon.
    ///
    /// Requires the underlying icon font to support the `opsz` [FontVariation]
    /// axis, otherwise has no effect. Variable font filenames often indicate
    /// the supported axes. Must be greater than 0.
    ///
    /// For an icon to look the same at different sizes, the stroke weight
    /// (thickness) must change as the icon size scales. Optical size offers a way
    /// to automatically adjust the stroke weight as icon size changes.
    ///
    /// Defaults to undefined.
    ///
    /// See also:
    ///  * [fill], for controlling fill.
    ///  * [weight], for controlling stroke weight.
    ///  * [grade], for controlling stroke weight in a more granular way.
    ///  * https://fonts.google.com/knowledge/glossary/optical_size_axis
    final double? opticalSize,

    /// The color to use when drawing the icon.
    ///
    /// Defaults to the [Colors.black].
    ///
    ///
    final Color color = Colors.black,

    /// A list of [Shadow]s that will be painted underneath the icon.
    ///
    /// Multiple shadows are supported to replicate lighting from multiple light
    /// sources.
    ///
    /// Shadows must be in the same order for [Icon] to be considered as
    /// equivalent as order produces differing transparency.
    ///
    /// Defaults to undefined.
    final List<Shadow>? shadows,

    /// An existing cursor that should be updated instead of creating a new cursor.
    /// This is used on DevicePixelRatio changes to update the cursors backing
    /// image.
    CustomMouseCursor? existingCursorToUpdate,
  }) async {
    assert(fill == null || (0.0 <= fill && fill <= 1.0));
    assert(weight == null || (0.0 < weight));
    assert(opticalSize == null || (0.0 < opticalSize));

    _CustomMouseCursorFromIconOriginInfo iconCreationInfo =
        _CustomMouseCursorFromIconOriginInfo(
      icon: icon,
      sizeInLogicalPixels: size,
      hotXInLogicalPixels: hotX,
      hotYInLogicalPixels: hotY,
      fill: fill,
      weight: weight,
      opticalSize: opticalSize,
      grade: grade,
      color: color,
      shadows: shadows,
    );
    double currentDevicePixelRatio =
        _getCurrentDevicePixelRatioFromLastConfigOrWindow();
    if (currentDevicePixelRatio != 1.0) {
      if (_Logger.logging) {
        _Logger.log(chalk.color.pink(
            '\n \n  \n   \nEntering ICON creation currentDevicePixelRatio=$currentDevicePixelRatio'));
        _Logger.log('  Must adjust size=$size   hotX=$hotX   hotY=$hotY ');
      }
      double adjustRatio = currentDevicePixelRatio / 1.0;
      size = size * adjustRatio;
      hotX = (hotX * adjustRatio).round();
      hotY = (hotY * adjustRatio).round();
      if (_Logger.logging) {
        _Logger.log('  ADJUSTED adjust size=$size   hotX=$hotX   hotY=$hotY ');
      }
    }

    ui.Image iconImage = _createImageFromIconSync(icon,
        size: size,
        color: color,
        iconFill: fill,
        iconWeight: weight,
        iconGrade: grade,
        iconOpticalSize: opticalSize,
        shadows: shadows);

    final cursor = await _commonCursorImageInstaller(iconImage, hotX, hotY,
        currentDevicePixelRatio /* WE MADE image/hotX/hotY match currentDevicePixelRatio!*/,
        originStory: CustomMouseCursorCreationType.icon,
        existingCursorToUpdate: existingCursorToUpdate);

    cursor._iconCreationInfo = iconCreationInfo;

    if (_Logger.logging) {
      _Logger.log(
          '  About to check for NEED TO CREATE 1x for web - IS WEB=$kIsWeb  _useURLDataURICursorCSS=$_useURLDataURICursorCSS  currentDevicePixelRatio=$currentDevicePixelRatio');
    }
    if (kIsWeb && _useURLDataURICursorCSS && currentDevicePixelRatio != 1.0) {
      // For web platform when using legacy URL datauri css cursors we need to always include
      // a 1.0 DPR version of the cursor.
      await _createDevicePixelRatio1xVersion(cursor);
    }

    return cursor;
  }

  /// Internal handler for updating custom icon cursors in response to changes to the system's devicePixelRatio.
  Future<void> _updateIconToNewDpi(double newDevicePixelRatio) async {
    assert(originStory == CustomMouseCursorCreationType.icon,
        '_updateIconToNewDpi() called on non icon cursor');

    if (_iconCreationInfo != null) {
      double scaleRatio = newDevicePixelRatio;
      double newSize = _iconCreationInfo!.sizeInLogicalPixels * scaleRatio;
      int newHotX =
          (_iconCreationInfo!.hotXInLogicalPixels * scaleRatio).round();
      int newHotY =
          (_iconCreationInfo!.hotYInLogicalPixels * scaleRatio).round();

      if (_Logger.logging) {
        _Logger.log(chalk.cyan(
            '  updateIconToNewDpi() making icon at newSize=$newSize   (scaleRatio=$scaleRatio)'));
      }
      ui.Image iconImage = _createImageFromIconSync(_iconCreationInfo!.icon,
          size: newSize,
          color: _iconCreationInfo!.color,
          iconFill: _iconCreationInfo!.fill,
          iconWeight: _iconCreationInfo!.weight,
          iconGrade: _iconCreationInfo!.grade,
          iconOpticalSize: _iconCreationInfo!.opticalSize,
          shadows: _iconCreationInfo!.shadows);
      if (_Logger.logging) {
        _Logger.log(
            '  CALLING image with EXISTING ICON IMAGE TO UPDATE WITH NEW icon Image newDevicePixelRatio=$newDevicePixelRatio');
      }
      await _commonCursorImageInstaller(
          iconImage, newHotX, newHotY, newDevicePixelRatio,
          originStory: CustomMouseCursorCreationType.icon,
          existingCursorToUpdate: this);
    }
  }

  /// Creates a [CustomMouseCursor] from the supplied ui.Image buffer.
  /// The [image] static method can be used to create icon's from [ui.Image] objects.
  /// The image will be scaled to create cursors for any other encounted devicePixelRatop.
  /// The image is supplied with it's native devicePixelRatio.  The image should have a devicePixelRatio
  /// large enough that it is scaled down for most encountered devicePixelRatios. (at least 2.0 typically).
  /// The [addImage] method can be used to supply additional images for specific devicePixelRatios.  These
  /// additional images are used only at their specific DPR.  The original image passed to [image] initially
  /// is always the one chosen for scaling for other encountered DPRs which do not exactly match the DPRs of
  /// any images added using [addImage].
  /// If [addImage] will be being called then pass [finalizeForCurrentDPR]=false to prevent the cursor
  /// from having a image made for the current DPR.
  static Future<CustomMouseCursor> image(
    ui.Image uiImage, {
    int hotX = 0,
    int hotY = 0,
    double thisImagesDevicePixelRatio = 1.0,
    bool finalizeForCurrentDPR = true,
    String? key,
  }) async {
    if (!thisImagesDevicePixelRatio.isFinite || thisImagesDevicePixelRatio <= 0) {
      throw ArgumentError.value(thisImagesDevicePixelRatio,
          'thisImagesDevicePixelRatio',
          'must be a finite, positive devicePixelRatio');
    }
    if (_Logger.logging) {
      _Logger.log(chalk.color.teal(
          'image() - creating custom cursor from ${thisImagesDevicePixelRatio}x image'));
    }
    final cursor = await _commonCursorImageInstaller(
        uiImage, hotX, hotY, thisImagesDevicePixelRatio);

    if (_Logger.logging) {
      _Logger.log(
          '  About to check for NEED TO CREATE 1x for web - IS WEB=$kIsWeb  _useURLDataURICursorCSS=$_useURLDataURICursorCSS  thisImagesDevicePixelRatio=$thisImagesDevicePixelRatio');
    }
    if (kIsWeb &&
        _useURLDataURICursorCSS &&
        thisImagesDevicePixelRatio != 1.0) {
      // For web platform when using legacy URL datauri css cursors we need to always include
      // a 1.0 DPR version of the cursor.
      await _createDevicePixelRatio1xVersion(cursor);
    }

    if (finalizeForCurrentDPR) {
      await cursor.finalizeImages();
    }
    return cursor;
  }

  /// Adds an additional image (at additional DPR) to the custom cursor.  This allows supplying additional images at
  /// other DevicePixelRatios.
  /// This can also replace existing dpr images previously set for this cursor.
  Future<void> addImage(
    ui.Image uiImage, {
    double thisImagesDevicePixelRatio = 1.0,
  }) async {
    if (!thisImagesDevicePixelRatio.isFinite ||
        thisImagesDevicePixelRatio <= 0) {
      throw ArgumentError.value(thisImagesDevicePixelRatio,
          'thisImagesDevicePixelRatio',
          'must be a finite, positive devicePixelRatio');
    }
    if (originStory != CustomMouseCursorCreationType.image) {
      throw ('addImage() called on CustomMouseCursor that was not created via image() ($originStory)');
    }
    if (_Logger.logging) {
      _Logger.log(chalk.color.lime(
          'addImage() - adding ${thisImagesDevicePixelRatio}x image to custom cursor'));
    }
    double rescaleRatioRequiredForImage =
        thisImagesDevicePixelRatio / nativeDevicePixelRatio;
    int hotX =
        (hotXAtNativeDevicePixelRatio * rescaleRatioRequiredForImage).round();
    int hotY =
        (hotYAtNativeDevicePixelRatio * rescaleRatioRequiredForImage).round();

    int width = uiImage.width;
    int height = uiImage.height;

    // get the uiImage as BGRA (for windows) or PNG for all other platforms.
    final imageBuffer = await _getImageBufferInPlatformSpecificFormat(uiImage);

    if (!kIsWeb) {
      _dprBitmapCache[thisImagesDevicePixelRatio] =
          _CustomMouseCursorDPRBitmapCache(
              imageBuffer, null, width, height, hotX, hotY);
    } else {
      // for the web we update this cursor's key with the new cursor definition that will now INCLUDE this
      // image definition as well.
      final base64ImageDataUri =
          _createDataURIForImage(imageBuffer, thisImagesDevicePixelRatio);
      // for the web the registeredKey *IS* the css cursor data-uri defining this cursor
      key = _createCursorCSSDefinition(
          base64ImageDataUri, hotX, hotY, thisImagesDevicePixelRatio, null);

      // Cache the base64ImageDataURI for possible later rebuilds of the cursor defintion with even more additional
      // images.
      _dprBitmapCache[thisImagesDevicePixelRatio] =
          _CustomMouseCursorDPRBitmapCache(
              imageBuffer, base64ImageDataUri, width, height, hotX, hotY);
    }
    if (_Logger.logging) {
      _Logger.log(
          '  addImage() SCALED hotspot by dpr/$nativeDevicePixelRatio => adjustHotSpotRatio=$rescaleRatioRequiredForImage  (changed to hotX=$hotX hotY=$hotY)');
    }
  }

  /// Adds an additional image (at additional DPR) to the custom cursor.  This allows supplying additional images at
  /// other DevicePixelRatios.
  /// This can also replace existing dpr images previously set for this cursor.
  Future<void> finalizeImages() async {
    if (originStory != CustomMouseCursorCreationType.image) {
      throw ('finalizeImages() called on CustomMouseCursor that was not created via image() ($originStory)');
    }
    double currentDevicePixelRatio =
        _getCurrentDevicePixelRatioFromLastConfigOrWindow();
    if (currentCursorDevicePixelRatio != currentDevicePixelRatio) {
      if (_Logger.logging) {
        _Logger.log(
            '  finalizeImages() Creating image icon version for current DPR of $currentDevicePixelRatio');
      }
      await _updateImageToNewDpi(currentDevicePixelRatio);
    }
  }

  /// Internal handler for updating custom image cursors in response to changes to the system's devicePixelRatio.
  Future<void> _updateImageToNewDpi(double newDevicePixelRatio) async {
    assert(originStory == CustomMouseCursorCreationType.image,
        '_updateImageToNewDpi() called on non image cursor ($originStory key=$key)');

    if (_Logger.logging) {
      _Logger.log(chalk.brightGreen(
          'ENTERING _updateImageToNewDpi( newDevicePixelRatio=$newDevicePixelRatio ) '));
    }
    // we at least need the original image in the cache so we can scale a new one..
    if (!_dprBitmapCache.containsKey(nativeDevicePixelRatio)) {
      throw ('_updateImageToNewDpi() could not find dpr entry of $nativeDevicePixelRatio to retreive original bitmap');
    }

    // Check to see if we have THIS DPR available in the cache and switch if possible...
    if (!await switchToCachedDevicePixelRatioIfPossible(newDevicePixelRatio)) {
      // OTHERWISE we were NOT able to find the DPR in the cache so create it

      // HOT SPOTS where orginally STORED at [nativeDevicePixelRatio] DPR (which may have changed from what user
      // passed to original asset()/exactasset() call), so we must adjust them with [nativeDevicePixelRatio]
      // from there to the [newDevicePixelRatio]
      double rescaleRatioRequiredForImage =
          newDevicePixelRatio / nativeDevicePixelRatio;
      double hotX = hotXAtNativeDevicePixelRatio * rescaleRatioRequiredForImage;
      double hotY = hotYAtNativeDevicePixelRatio * rescaleRatioRequiredForImage;

      if (_Logger.logging) {
        _Logger.log(
            '  nativeDevicePixelRatio=$nativeDevicePixelRatio  cache has _dprBitmapCache=$_dprBitmapCache');
        _Logger.log(
            '  _updateImageToNewDpi() updating by SCALING image/hotspot by adjustHotSpotRatio=$rescaleRatioRequiredForImage  (changed to hotX=$hotX hotY=$hotY)');
      }
      late final ui.Image uiImage;
      if (!kIsWeb && Platform.isWindows) {
        // On windows our buffer is in raw BGRA format..
        final cacheEntry = _dprBitmapCache[nativeDevicePixelRatio]!;
        final rawBgraUint8 = cacheEntry.imageBuffer;

        if (_Logger.logging) {
          _Logger.log(chalk.red.onBrightWhite(
              'about to use decodeImageFromPixels() to decode BRGA buffer and scale'));
        }
        // Decode our raw BGRA pixel buffer back to a uiImage.
        final Completer<ui.Image> completer = Completer<ui.Image>();
        decodeImageFromPixels(
          rawBgraUint8,
          cacheEntry.width,
          cacheEntry.height,
          PixelFormat.bgra8888,
          completer.complete,
          targetWidth:
              (cacheEntry.width * rescaleRatioRequiredForImage).round(),
          targetHeight:
              (cacheEntry.height * rescaleRatioRequiredForImage).round(),
          allowUpscaling: true,
        );
        uiImage = await completer.future;
        if (_Logger.logging) {
          _Logger.log(chalk.red.onBrightWhite(
              'DONE WITH decodeImageFromPixels() width=${uiImage.width} height=${uiImage.height}'));
        }
      } else {
        if (_Logger.logging) {
          _Logger.log(chalk.red(
              '_dprBitmapCache.containsKey(nativeDevicePixelRatio)=${_dprBitmapCache.containsKey(nativeDevicePixelRatio)}'));
        }
        final rawUint8 = _dprBitmapCache[nativeDevicePixelRatio]!.imageBuffer;

        if (_Logger.logging) {
          _Logger.log(chalk.red.onBrightWhite(
              'about to call _createUIImageFromUint8ListBufferPossiblyScale()'));
        }
        uiImage = await _createUIImageFromPNGUint8ListBufferAndPossiblyScale(
            rawUint8,
            rescaleRatioRequiredForImage: rescaleRatioRequiredForImage);
        if (_Logger.logging) {
          _Logger.log(chalk.red.onBrightWhite(
              'BACK FROM call to _createUIImageFromUint8ListBufferPossiblyScale()'));
        }
      }
      if (_Logger.logging) {
        _Logger.log(
            '  _updateImageToNewDpi() UPDATE Asset loaded image width=${uiImage.width} height=${uiImage.height}');
        _Logger.log(
            '  calling image() with EXISTING ASSET CURSOR newDevicePixelRatio=$newDevicePixelRatio');
      }
      await _commonCursorImageInstaller(
          uiImage, hotX.round(), hotY.round(), newDevicePixelRatio,
          key: key,
          originStory: CustomMouseCursorCreationType.image,
          existingCursorToUpdate: this);
    }
  }

  /// _commonCursorImageInstaller() creates cursor from ui.Image.  This is primarily an internal method for the asset(),
  /// exactasset() and icon() methods.  It is left exposed to allow for flexibilty of user's creating cursors
  /// from any ui.Image.
  /// [uiImage] specifies the [ui.Image] object to create the icon from.
  /// [thisImagesDevicePixelRatio] specifies the DPR of the ui.Image.
  /// [hotX],[hotY] specify the location of the cursor hotspot in the DPR specified by [thisImagesDevicePixelRatio].
  ///  the Native DevicePixelRatio for this size.
  /// [key] optionally specifies the key of this image - this may be completely disregard on some platforms,
  ///   on web platforms it will dynmically be replaces as this is the cursor definition.
  ///   This can be left null and the system will handle it's assignment.
  /// [originStory] is used to specify how this image was originally created.  The [CustomMouseCursorCreationType] class
  /// is private so external users can not change this parameter from the default.
  static Future<CustomMouseCursor> _commonCursorImageInstaller(
    ui.Image uiImage,
    int hotX,
    int hotY,
    double thisImagesDevicePixelRatio, {
    String? key,
    CustomMouseCursorCreationType originStory =
        CustomMouseCursorCreationType.image,

    /// An existing cursor that should be updated instead of creating a new cursor.
    /// This is used on DevicePixelRatio changes to update the cursors backing
    /// image.
    CustomMouseCursor? existingCursorToUpdate,
  }) async {
    if (_Logger.logging) {
      _Logger.log(chalk.brightWhite(
          'ENTERING _commonCursorImageInstaller() with existingCursorToUpdate=$existingCursorToUpdate'));
    }
    // todo: tmm - Maybe not best place but ensure we have callbacks to detect DevicePixelRatio changes ?
    _setupViewsOnMetricChangedCallbacks();

    int width = uiImage.width;
    int height = uiImage.height;

    late double currentDevicePixelRatio;
    // If we have a ImageConfiguration object already from didChangeDependencies() being called
    // use that to use AssetImage to do a DPI aware loading of the pointer
    if (_lastImageConfiguration != null) {
      if (_Logger.logging) {
        _Logger.log(
            '  Using lastImageConfiguration devicePixelRatio = ${_lastImageConfiguration?.devicePixelRatio ?? 'ImageConfiguration MISSING DEVICEPIXELRATIO'}');
      }
      currentDevicePixelRatio =
          _getCurrentDevicePixelRatioFromLastConfigOrWindow();
    } else {
      // Otherise get the device pixel ratio for current window.
      // todo: tmm fix this deprecated code once there is a common way in stable
      currentDevicePixelRatio = _getCurrentDevicePixelRatioFromWindow();
      if (_Logger.logging)
        _Logger.log(
            '  _commonCursorImageInstaller() existingCursorToUpdate=$existingCursorToUpdate  Current currentDevicePixelRatio from WidgetsBinding! devicePixelRatio = $currentDevicePixelRatio');
    }

    // If a different DPR was sent for the image other that does NOT match the [currentDevicePixelRatio] then
    // the passed [thisImagesDevicePixelRatio] will be used.  (We assume caller knows what they want)
    if (currentDevicePixelRatio != thisImagesDevicePixelRatio) {
      if (_Logger.logging) {
        _Logger.log(
            '  !!!!!! In _commonCursorImageInstaller() Creation and thisImagesDevicePixelRatio DPR ($currentDevicePixelRatio) != NATIVE ($thisImagesDevicePixelRatio)');
      }
      currentDevicePixelRatio = thisImagesDevicePixelRatio;
      if (_Logger.logging) {
        _Logger.log(
            '  CHANGED CURRENT TO MATCH thisImagesDevicePixelRatio=$thisImagesDevicePixelRatio FOR THIS CREATION');
      }
    }

    // get the uiImage as BGRA (for windows) or PNG for all other platforms.
    final imageBuffer = await _getImageBufferInPlatformSpecificFormat(uiImage);

    if (existingCursorToUpdate == null) {
      // CREATING A NEW CURSOR
      if (_Logger.logging) {
        _Logger.log('  in _commonCursorImageInstaller() CREATING NEW CURSOR');
      }
      // if no key was passed in we generate a random unique key
      key ??= generateUniqueKey();

      late final String registeredKey;
      String? base64ImageDataUri;
      if (!kIsWeb) {
        registeredKey =
            await _CustomMouseCursorPlatformInterface.registerCursor(key,
                imageBuffer, width, height, hotX.toDouble(), hotY.toDouble(),
                scale: thisImagesDevicePixelRatio);
        assert(registeredKey == key);
      } else {
        // for the web the registeredKey *IS* the css cursor data-uri defining this cursor
        base64ImageDataUri =
            _createDataURIForImage(imageBuffer, thisImagesDevicePixelRatio);

        registeredKey = _createCursorCSSDefinition(
            base64ImageDataUri, hotX, hotY, thisImagesDevicePixelRatio, null);
      }
      final cursor = CustomMouseCursor._(registeredKey, originStory,
          thisImagesDevicePixelRatio, hotX, hotY, currentDevicePixelRatio);

      if (!kIsWeb) {
        cursor._dprBitmapCache[thisImagesDevicePixelRatio] =
            _CustomMouseCursorDPRBitmapCache(
                imageBuffer, null, width, height, hotX, hotY);
      } else {
        // Cache the base64ImageDataURI
        cursor._dprBitmapCache[thisImagesDevicePixelRatio] =
            _CustomMouseCursorDPRBitmapCache(
                imageBuffer, base64ImageDataUri, width, height, hotX, hotY);

        if (_Logger.logging) {
          _Logger.log(
              'WEB Added TO CACHE for thisImagesDevicePixelRatio=$thisImagesDevicePixelRatio  !!');
        }
        //NO LONGER NEEDED//cursor._dprCSSCursorCache[thisImagesDevicePixelRatio] = registeredKey;
      }

      _cursorCacheOfAllCreatedCursors[key] = cursor;

      return cursor;
    } else {
      /*
        This is an EXISTING cursor and we are going to update it with a new DPR version of
        the cursor.
      */
      key = existingCursorToUpdate.key;
      if (_Logger.logging) {
        _Logger.log(
            '  WE ARE in _commonCursorImageInstaller() UPDATING the backing image key=${_debugPrintPossibleCSSDataUriString(key)} ');
      }
      // WE ARE UPDATING an existing cursor's backing image, so delete previous image and
      if (!kIsWeb) {
        // delete previous version
        _CustomMouseCursorPlatformInterface.deleteCursor(key);
        // and create new version with new dpi image
        String newRegisteredKey =
            await _CustomMouseCursorPlatformInterface.registerCursor(key,
                imageBuffer, width, height, hotX.toDouble(), hotY.toDouble(),
                scale: thisImagesDevicePixelRatio);

        existingCursorToUpdate._dprBitmapCache[thisImagesDevicePixelRatio] =
            _CustomMouseCursorDPRBitmapCache(
                imageBuffer, null, width, height, hotX, hotY);

        assert(newRegisteredKey == key);
      } else {
        // for the web the registeredKey *IS* the css cursor data-uri defining this cursor
        final base64ImageDataUri =
            _createDataURIForImage(imageBuffer, thisImagesDevicePixelRatio);
        existingCursorToUpdate._dprBitmapCache[thisImagesDevicePixelRatio] =
            _CustomMouseCursorDPRBitmapCache(
                imageBuffer, base64ImageDataUri, width, height, hotX, hotY);

        existingCursorToUpdate.key = _createCursorCSSDefinition(
            base64ImageDataUri,
            hotX,
            hotY,
            thisImagesDevicePixelRatio,
            existingCursorToUpdate._dprBitmapCache);
      }
      existingCursorToUpdate.currentCursorDevicePixelRatio =
          thisImagesDevicePixelRatio;
      return existingCursorToUpdate;
    }
  }

  // Calls the approriate updateXXXXToNewDpi() method depending on this cursor's type ([originStory]).
  Future<void> _updateCursorToNewDpr(double newDevicePixelRatio) async {
    if (_Logger.logging) {
      _Logger.log(
          '    UPDATING $originStory CURSOR dpr - CALLING cursor.updateXXXXToNewDpi( $newDevicePixelRatio );');
    }
    if (originStory == CustomMouseCursorCreationType.asset ||
        originStory == CustomMouseCursorCreationType.exactasset) {
      await _updateAssetToNewDpi(newDevicePixelRatio);
    } else if (originStory == CustomMouseCursorCreationType.icon) {
      await _updateIconToNewDpi(newDevicePixelRatio);
    } else if (originStory == CustomMouseCursorCreationType.image) {
      await _updateImageToNewDpi(newDevicePixelRatio);
    }
  }

  // Switch this cursor to a different DPR if it is found in the cache.  Returns
  // true if [desiredDevicePixelRatio] is in the cache and the switch is made.
  // false if [desiredDevicePixelRatio] is not found in the cache.
  Future<bool> switchToCachedDevicePixelRatioIfPossible(
      double desiredDevicePixelRatio) async {
    if (false && _Logger.logging) {
      _Logger.log(chalk.red(
          'switchToCachedDevicePixelRatioIfPossible($desiredDevicePixelRatio) _dprBitmapCache.containsKey($_dprBitmapCache.containsKey(desiredDevicePixelRatio))=${_dprBitmapCache.containsKey(desiredDevicePixelRatio)}'));
    }
    // First we check this cursors DPR cache
    // If it's in our cache then switch to the cached image for this DPR.
    if (_dprBitmapCache.containsKey(desiredDevicePixelRatio)) {
      if (!kIsWeb) {
        if (_Logger.logging) {
          _Logger.log(
              '    Getting DPR $desiredDevicePixelRatio from cursors BITMAP cache!!!');
        }
        final cachedInfo = _dprBitmapCache[desiredDevicePixelRatio]!;
        // WE ARE UPDATING an existing cursor's backing image, so delete previous image and
        await _CustomMouseCursorPlatformInterface.deleteCursor(key);
        // get new version with new dpi image
        await _CustomMouseCursorPlatformInterface.registerCursor(
            key,
            cachedInfo.imageBuffer,
            cachedInfo.width,
            cachedInfo.height,
            cachedInfo.hotX.toDouble(),
            cachedInfo.hotY.toDouble(),
            scale: desiredDevicePixelRatio);
        currentCursorDevicePixelRatio = desiredDevicePixelRatio;
        return true;
      } else {
        // For the web we just need to see if this DPR is in our cache, if it IS then we
        // now it is ALREADY in the existing defintion of the cursor and we can continue.
        // WE found this DPU in the cache so we know it is included in the cursor defintion
        if (_Logger.logging) {
          _Logger.log(
              '     Found DPR $desiredDevicePixelRatio from cursors cache!!!  WE CAN SKIP THISONE');
        }
        currentCursorDevicePixelRatio = desiredDevicePixelRatio;
        return true;
      }
    }
    // not in our DPR cache
    return false;
  }

  /// Creates a CSS URL Data URI with the image definition
  static String _createDataURIForImage(
      Uint8List imageBuffer, double forDebugging) {
    final base64ImageDataUri =
        base64.encode(imageBuffer); //.replaceAll('\n','').replaceAll('\r','');
    //TRACKINGDEBUG//final base64ImageDataUri = ' IMAGE-DATAURI FOR  DPR-$forDebugging';
    return 'url("data:image/png;base64,$base64ImageDataUri")';
  }

  /// Whether or not to use '-webkit-image-set' or 'image-set' for CSS.  Currently the '-webkit-image-set' is the more
  /// widely useable CSS command until full adoption.
  /// Defaults to true.
  static bool useWebKitImageSet = true;

  /// If set then ONLY image-set() style CSS cursor defintions will be generated.  These are new
  /// versions which properly support higher resolution devicePixelRatio cursors, such as 2.0x and 3.0x.
  /// If set then the older 'url()' style CSS cursor definitions WILL NOT BE included at all.
  /// This reduces the size of the cursor defintion and can save time by preventing the need to generate
  /// a 1.0x image on systems where the screen devicePixelRatio is 2.0x (or at least not 1.0x).
  /// (Older style CSS cursor defintions must be supplied 1.0x images because the browser scales them up as necessary
  /// in that case.   If image-set style CSS cursors are being generated anyway the only time the older url() style
  /// defintions are needed is to support older browsers.  At some point the url() style defintions will not be needed
  /// at all as all browsers will support image-set.)
  static set useOnlyImageSetCSS(bool newVal) {
    if (newVal) {
      _useURLDataURICursorCSS = false;
    }
    _useImageSetCSS = true;
  }

  static bool get useOnlyImageSetCSS =>
      _useImageSetCSS && !_useURLDataURICursorCSS;
  static bool _useImageSetCSS = true;

  /// If set then ONLY the older 'url()' style CSS cursor definition will be included.  Image-set cursor defintions will
  /// not be included at all.   All cursors will be generated at 1.0x only and scaled up when needed.  This will result
  /// in pixelated cursors on 2.0x and higher systems as no higher resolution cursors will be able to be supplied
  /// using image-set().
  /// (Older style url() CSS cursor defintions must be supplied 1.0x images only as the browser ALWAYS scales them up
  /// to match the devicePixelRatio and assumes that they are being supplied as 1.0x only).
  static set useOnlyURLDataURICursorCSS(bool newVal) {
    if (newVal) {
      _useImageSetCSS = false;
    }
    _useURLDataURICursorCSS = true;
  }

  static String _debugPrintPossibleCSSDataUriString(String str) {
    if (!kIsWeb || str.length <= 70) return str;

    // otherwise this is a longer css style string, remove datauri bulk
    return '${str.substring(0, 35)} ... ${str.substring(str.length - 35)}';
  }

  static bool get useOnlyURLDataURICursorCSS =>
      _useURLDataURICursorCSS && !_useImageSetCSS;
  static bool _useURLDataURICursorCSS = true;

  /// Makes a CSS cursor definition string
  /// This function will include BOTH 'image-set' and 'url' versions of the
  /// CSS cursor definition unless [_useOnlyImageSetCSS] is true in which
  /// case it will create image-set css only.
  /// If [_useOnlyURLDataURICursorCSS] is true then only URL DataURI
  /// versions of cursors will be created.
  /// NOTE: There is a special case we need to handle - If the [nativeDevicePixelRatio] is NOT 1.0x,
  /// and [_useURLDataURICursorCSS] is true we MUST have a 1.0x image to include in the
  /// cursor definitions, browsers expect 1.0x bitmap that THEY will scale when not using image-set.
  /// If there is not a 1.0x version of the bitmap in the cursors cache, then WE must create one.
  static String _createCursorCSSDefinition(
      String base64ImageDataUri,
      int hotX,
      int hotY,
      double nativeDevicePixelRatio,
      Map<double, _CustomMouseCursorDPRBitmapCache>? dprBitmapCache) {
    if (_Logger.logging) {
      _Logger.log(chalk.bgYellow(
          'Entered _createCursorCSSDefinition() and nativeDevicePixelRatio=$nativeDevicePixelRatio  dprBitmapCache=$dprBitmapCache'));
    }
    //TRACKINGDEBUG//base64ImageDataUri='  ADDING DPR=$nativeDevicePixelRatio ';

    String imageset = '';
    String urldatauri = '';
    if (nativeDevicePixelRatio != 1.0) {
      // hotX and hotY must be in 1.0x location
      hotX = (hotX / nativeDevicePixelRatio).round();
      hotY = (hotY / nativeDevicePixelRatio).round();
    }
    String? dpr1Base64ImageDataUri;
    if (nativeDevicePixelRatio == 1.0) {
      dpr1Base64ImageDataUri = base64ImageDataUri;
    }
    if (_useImageSetCSS) {
      if (dprBitmapCache != null) {
        // If we have the cache WE KNOW that the [base64ImageDataUri] is already present in the cache,
        // (because it was added to cache before this call to createCursorCSSDefinition()
        // so we don't need to worry about including [base64ImageDataUri] separately.
        if (_Logger.logging) {
          _Logger.log('  LOOPING on cache');
        }
        // first get sizes and sort
        final dprs = dprBitmapCache.keys;

        if (_Logger.logging) {
          _Logger.log('  dpr key list = $dprs');
        }
        // LOOP over all bitmaps in the cache and generate our multi DPR image-set defintion
        StringBuffer innerimageset = StringBuffer();
        for (final dpr in dprs) {
          if (_Logger.logging) {
            _Logger.log(
                '  Current DRP = $dpr   datauri=${_debugPrintPossibleCSSDataUriString(dprBitmapCache[dpr]!.base64ImageDataUri!)}');
          }
          String curDprBase64ImageDataUri =
              dprBitmapCache[dpr]!.base64ImageDataUri!;
          if (innerimageset.isNotEmpty) innerimageset.write(', ');
          innerimageset.write('$curDprBase64ImageDataUri ${dpr}x');
          if (dpr == 1.0) {
            dpr1Base64ImageDataUri = curDprBase64ImageDataUri;
          }
        }
        imageset =
            '${useWebKitImageSet ? '-webkit-image-set' : 'image-set'}( $innerimageset ) $hotX $hotY';
      } else {
        // single image
        imageset =
            '${useWebKitImageSet ? '-webkit-image-set' : 'image-set'}( $base64ImageDataUri ${nativeDevicePixelRatio}x ) $hotX $hotY';
      }
    }
    // It is possible that we wont have [dprBase64ImageDataUri] yet, but if we need one then
    // [createDevicePixelRatio_1x_Version()] will be called later and we will update it.
    if (_useURLDataURICursorCSS && dpr1Base64ImageDataUri != null) {
      urldatauri = '$dpr1Base64ImageDataUri $hotX $hotY';
    }
    // This will create a CSS cursor url that will look something like (if this is a 2x devicePixelRatio case)
    // "image-set( url(data1...) 1x, url(data2..) 2x ) 10 10, url(data1) 10 10, pointer"
    // which will have image-set() version with 1x and 2x devicePixelRatios, a fallback older
    // CSS style cursor with just a url(datauri) with a 1x image that will be scaled up on machines with
    // higher DPR, and then a finally a 'pointer' fallback if the browser could handle the first 2 cases.
    final ret =
        '${imageset != '' ? '$imageset, ' : ''}${urldatauri != '' ? '$urldatauri, ' : ''}pointer';

    if (_Logger.logging) {
      _Logger.log(
          '  LEAVING createCursorCSSDefinition() MADE CURSOR= "${_debugPrintPossibleCSSDataUriString(ret)}"!!!!');
    }
    return ret;
  }

  // ACTUALLY make DELAY creating cursor till HERE??? -
  // todo: tmm  Currently decided this does not help in any meaningful way
  @override
  MouseCursorSession createSession(int device) =>
      _CustomMouseCursorSession(this, device);

  @override
  String get debugDescription => objectRuntimeType(this, 'CustomMouseCursor');

  /// Returns true if this cursor object is still valid and it's platform backing
  /// cursor has not been deleted.  For web it always returns true as the
  /// cursor's key is the platform definition.
  bool get isValid =>
      kIsWeb || _cursorCacheOfAllCreatedCursors.containsKey(key);

  /// For cursors that have a backing platform cursor this frees that cursor and
  /// removes this cursor from the [_cursorCacheOfAllCreatedCursors].
  void dispose() {
    if (!kIsWeb) {
      _CustomMouseCursorPlatformInterface.deleteCursor(key);
      _cursorCacheOfAllCreatedCursors.remove(key);
    }
  }

  /// Disposes of all created cursors.
  static void disposeAll() {
    if (_Logger.logging) {
      _Logger.log('disposeAll() called');
    }
    for (final cursor in _cursorCacheOfAllCreatedCursors.values) {
      if (_Logger.logging) {
        _Logger.log(
            'Calling dispose on ${_debugPrintPossibleCSSDataUriString(cursor.key)}');
      }
      cursor.dispose();
    }
    _cursorCacheOfAllCreatedCursors.clear();
  }

  static ImageConfiguration? _lastImageConfiguration;
  static double _lastEnsuredDevicePixelRatio = 0;

  /// This method creates a DPR 1.0x version of the cursor for the WEB platform for use in the
  /// older CSS url() style cursor defintions (where 1.0x is ASSUMED by the browser).
  /// If the platform is NOT web, or older style URL cursors are not being included in the defintion
  /// ([_useURLDataURICursorCSS] is false) then this method returns immediately.
  static Future<void> _createDevicePixelRatio1xVersion(
      CustomMouseCursor cursor) async {
    if (_Logger.logging) {
      _Logger.log('ENTERING _createDevicePixelRatio1xVersion() entered');
    }
    if (!kIsWeb ||
        !_useURLDataURICursorCSS ||
        cursor._dprBitmapCache.containsKey(1.0)) {
      // this cursor alreay has a 1.0 DPR version present so it is set
      if (_Logger.logging &&
          cursor._dprBitmapCache.containsKey(1.0)) {
        _Logger.log(
            '   We found the 1.0X KEY - existing  _createDevicePixelRatio1xVersion()!!!!!');
      }
      if (_Logger.logging) {
        _Logger.log(
            'SHORT CIRCUIT exit _createDevicePixelRatio1xVersion() without having to do anything cursor._dprBitmapCache.containsKey(1.0)=${cursor._dprBitmapCache.containsKey(1.0)} kIsWeb=$kIsWeb  _useURLDataURICursorCSS=$_useURLDataURICursorCSS  ');
      }
      return;
    }

    // Because this is the WEB PLATFORM only when we call _updateCursorToNewDpi(1.0)
    // toe ADD the 1.0x cursor image to the existing cursor definition.
    await cursor._updateCursorToNewDpr(1.0);

    if (_Logger.logging) {
      _Logger.log('LEAVING _createDevicePixelRatio1xVersion()');
    }
  }

  /// This method ensures that all pointers have support for any changes to the devicePixelRatio
  /// This can happen on windows moving to new monitors with different DPR or by changing system
  /// settings for display.
  /// This is called from our onMetricsChanged() hook or by user themselves (typically from their
  /// root widget's didChangeDependencies() handler.
  static void ensurePointersMatchDevicePixelRatio(BuildContext? context) async {
    if (_Logger.logging) {
      _Logger.log(
          chalk.color.hotpink('ENTERED ensurePointersMatchDevicePixelRatio()'));
    }
    double devicePixelRatio = _getDevicePixelRatioFromView();
    if (devicePixelRatio == _lastEnsuredDevicePixelRatio) {
      if (_Logger.logging) {
        _Logger.log(chalk.brightBlue(
            '  lastEnsuredDevicePixelRatio IMMEDIATE RETURN already $_lastEnsuredDevicePixelRatio'));
      }
      return;
    }

    _lastImageConfiguration =
        _createLocalImageConfigurationWithOrWithoutContext(context: context);

    double currentDevicePixelRatio =
        _lastImageConfiguration?.devicePixelRatio ?? devicePixelRatio;

    if (_Logger.logging) {
      _Logger.log(
          '  Determined Current currentDevicePixelRatio= $currentDevicePixelRatio');
      _Logger.log(
          '  createLocalImageConfiguration  devicePixelRatio=${_lastImageConfiguration!.devicePixelRatio}  platform=${_lastImageConfiguration!.platform}');
      _Logger.log(
          '\n\n  CHECKING ALL CURSORS==============================================');
    }
    for (final cursor in _cursorCacheOfAllCreatedCursors.values) {
      if (_Logger.logging) {
        _Logger.log(
            '\n--------------------------------------------------------\n    Checking DPR for cursor.originStory=${cursor.originStory}  key=${_debugPrintPossibleCSSDataUriString(cursor.key)}  ');
      }
      if (cursor.currentCursorDevicePixelRatio != currentDevicePixelRatio) {
        if (_Logger.logging) {
          _Logger.log(
              '    Current DPI is different than cursors DPI!!!    cursor.currentCursorDevicePixelRatio=${cursor.currentCursorDevicePixelRatio} != currentDevicePixelRatio=$currentDevicePixelRatio');
        }
        if (await cursor.switchToCachedDevicePixelRatioIfPossible(
            currentDevicePixelRatio)) {
          // found in cache
          continue;
        }
        // not in cache, so go create new cursor bitmap for this DPR
        await cursor._updateCursorToNewDpr(currentDevicePixelRatio);
      }
    }
    _lastEnsuredDevicePixelRatio = currentDevicePixelRatio;
    if (_Logger.logging) {
      _Logger.log('  LEAVING ensurePointersMatchDevicePixelRatio()!!!!!');
    }
  }

  /// Our onMetricsChanged() callback
  /// Curiously this takes no args and we have to detect where it came from OURSELVES ??
  /// todo: tmm  clean this up once flutter mutliwindow stuff is complete
  static void onMetricsChanged() {
    ensurePointersMatchDevicePixelRatio(null);
  }

  /// If a context is supplied then [createLocalImageConfiguration] is used as normal to create the [ImageConfiguration]
  /// object.  Otherwise the devicePixelRatio from [PlatformDispatcher] is used (or the [foreceDevicePixelRatio] value)
  /// to create a ImageConfiguration().
  static ImageConfiguration _createLocalImageConfigurationWithOrWithoutContext(
      {BuildContext? context, double? forceDevicePixelRatio}) {
    if (forceDevicePixelRatio != null || context == null) {
      // MAKE our own default ImageConfiguration() with devicePixelRatio from PlatformDispatcher
      // or the supplied forceDevicePixelRatio.
      final returnImageConfiguration = ImageConfiguration(
        bundle: rootBundle,
        devicePixelRatio:
            forceDevicePixelRatio ?? _getDevicePixelRatioFromView(),
        locale: PlatformDispatcher.instance.locale,
        textDirection: TextDirection.ltr,
        size: null,
        platform: defaultTargetPlatform,
      );
      if (forceDevicePixelRatio == null) {
        // ONLY REMEMBER THIS AS [_lastImageConfiguration] if it was NOT FORCED
        _lastImageConfiguration = returnImageConfiguration;
      }
      return returnImageConfiguration;
    } else {
      // we were supplied a [context] so use that to get create [ImageConfiguration].
      _lastImageConfiguration = createLocalImageConfiguration(context);
      return _lastImageConfiguration!;
    }
  }

  static bool _noOnMetricsChangedHook = false;

  /// This method allows user to specify that they don't want us to hook the onMetricsChanged() - this is
  /// included because if we hook it then it will conflict with user's hook, so we must provide
  /// way to opt out.  If user opts out they must MANUALLY call `CustomMouseCursor.ensurePointersMatchDevicePixelRatio(context)`.
  static set noOnMetricsChangedHook(bool newVal) {
    if (!_noOnMetricsChangedHook && newVal && _onMetricChangedCallbackSet) {
      throw ('CustomMouseCursor aleady hooked onMetricsChanged() - set noOnDeviceMetricsHook BEFORE creating cursors');
    }
    _noOnMetricsChangedHook = newVal;
  }

  static bool get noOnMetricsChangedHook {
    return _noOnMetricsChangedHook && !_onMetricChangedCallbackSet;
  }

  /// If true we use [WidgetsBinding.instance.platformDispatcher.onMetricsChanged] to hook [onMetricsChanged],
  /// if false we use the [WidgetsBinding.instance.platformDispatcher.views] array and hook the [onMetricsChanged]
  /// for each view.
  static bool _usePlatformDipatcherOnMetricsChanged = true;

  /// This method allows user to specify that the want us to use the [WidgetsBinding.instance.platformDispatcher.views]
  /// array to then hook the [onMetricsChanged] for each view.
  /// If this is not set to true then the default (pre-multiple views) method of using
  /// [WidgetsBinding.instance.platformDispatcher.onMetricsChanged] to hook the [onMetricsChanged]
  static set useViewsForOnMetricsChangedHook(bool newVal) {
    if (!_usePlatformDipatcherOnMetricsChanged &&
        newVal &&
        _onMetricChangedCallbackSet) {
      throw ('CustomMouseCursor aleady hooked onMetricsChanged() - set useViewsForOnMetricsChangedHook BEFORE creating cursors');
    }
    _usePlatformDipatcherOnMetricsChanged = !newVal;
  }

  static bool get useViewsForOnMetricsChangedHook {
    return !_usePlatformDipatcherOnMetricsChanged;
  }

  static bool _onMetricChangedCallbackSet = false;

  static bool _multiWindowsSetupDetected = false;

  /// get current devicePixelRatio from WigetsBinding.instance.window - WARNING deprecated
  /// todo: tmm - this is not multiwindow aware, uses deprecated `window`, but works in stable channel
  static double _getCurrentDevicePixelRatioFromWindow() {
    // ICARUS PATCH: macOS is no longer clamped to 1.0 DPR. The macOS plugin
    // now accepts a `scale` argument and sets the NSImage point size, so
    // Retina displays get full-resolution cursors.
    if (PlatformDispatcher.instance.implicitView == null) {
      _multiWindowsSetupDetected = true;
      throw ('CustomMouseCursor detected null PlatformDispatcher.instance.implicitView which means Multiple Window Environment _multiWindowsSetupDetected=$_multiWindowsSetupDetected');
    }
    return PlatformDispatcher.instance.implicitView!.devicePixelRatio;
    //OLD DEPRECATED WAY//return WidgetsBinding.instance.window.devicePixelRatio;
  }

  /// get current devicePixelRatio from either [_lastImageConfiguration] or from the
  /// flutter window instance.
  /// todo: tmm - this is not multiwindow aware, uses deprecated `window`, but works in stable channel
  static double _getCurrentDevicePixelRatioFromLastConfigOrWindow() {
    // ICARUS PATCH: macOS is no longer clamped to 1.0 DPR. The macOS plugin
    // now accepts a `scale` argument and sets the NSImage point size, so
    // Retina displays get full-resolution cursors.
    if (_lastImageConfiguration != null &&
        _lastImageConfiguration!.devicePixelRatio != null) {
      return _lastImageConfiguration!.devicePixelRatio!;
    }
    if (PlatformDispatcher.instance.implicitView == null) {
      _multiWindowsSetupDetected = true;
      throw ('CustomMouseCursor detected null PlatformDispatcher.instance.implicitView which means Multiple Window Environment _multiWindowsSetupDetected=$_multiWindowsSetupDetected');
    }
    return PlatformDispatcher.instance.implicitView!.devicePixelRatio;
    //DEPRECATED WAY//return _lastImageConfiguration?.devicePixelRatio ??
    //DEPRECATED WAY//    WidgetsBinding.instance.window.devicePixelRatio;
  }

  /// Various ways of getting current DevicePixelRatio - included here are various methods for OLD/New Flutter,
  /// some basis for future multi window support.
  static double _getDevicePixelRatioFromView() {
    if (kIsWeb && _useURLDataURICursorCSS && !_useImageSetCSS) {
      // If we are using ONLY URL data uri cursors and NOT image-set(), so ONLY 1.0x images will
      // be generated and browser will scale them.  We won't be able to give DPR specific versions of images
      // without image-set.
      return 1.0;
    }

    //DEPRECATED WAY//if (_usePreFlutter39) {
    //DEPRECATED WAY//  // deprecated way to get pixel ratio
    //DEPRECATED WAY//  return WidgetsBinding.instance.window.devicePixelRatio;
    //DEPRECATED WAY//}

    // Flutter 3.9
    if (PlatformDispatcher.instance.implicitView == null) {
      _multiWindowsSetupDetected = true;
      throw ('CustomMouseCursor detected null PlatformDispatcher.instance.implicitView which means Multiple Window Environment _multiWindowsSetupDetected=$_multiWindowsSetupDetected');
    }

    if (_Logger.logging) {
      _Logger.log(chalk.color.orange(
          'getDevicePixelRatioFromView() called    :  usePlatformDipatcherOnMetricsChanged=$_usePlatformDipatcherOnMetricsChanged'));
    }
    late double devicePixelRatio;
    if (_usePlatformDipatcherOnMetricsChanged) {
      devicePixelRatio =
          PlatformDispatcher.instance.implicitView!.devicePixelRatio;
    } else {
      // look at all views - verify that if there are >1 they all have same devicePixelRatio
      //  This of course will not always be true, but we THROW on it because we need to develop and
      //  test for mulitple window/views ONCE IT IS IMPLENTED IN FLUTTER -
      //  it is not yet. This is just to FORCE REVISTING THIS once it is. --tmm
      // TODO: tmm  Finish multi view/window support once it is implemented in flutter
      double? foundDevicePixelRatio;
      for (final view in WidgetsBinding.instance.platformDispatcher.views) {
        if (_Logger.logging) {
          _Logger.log(
              'View is DPR ${view.devicePixelRatio}   view.viewId=${view.viewId}');
        }
        if (foundDevicePixelRatio == null) {
          foundDevicePixelRatio = view.devicePixelRatio;
        } else {
          // VERIFY THEY ARE ALL SAME devicePixelRatio
          if (view.devicePixelRatio != foundDevicePixelRatio) {
            throw ('Difference devicePixelRatio found on different views - WE HAVE NOT TESTED/DEVELOPED for this yet.');
          }
        }
      }
      if (foundDevicePixelRatio == null) {
        throw ('getDevicePixelRatioFromView() did not find views/devicePixelRatio');
      }
      devicePixelRatio = foundDevicePixelRatio;
    }
    if (_Logger.logging) {
      _Logger.log('  RETURNING lastDevicePixelRatio=$devicePixelRatio');
    }
    return devicePixelRatio;
  }

  /// We hook into the system's onMetricsChanged() callbacks using one mechanism or another...
  /// Options here for old and new flutter systems and roots of support for upcoming multi-window support.
  static void _setupViewsOnMetricChangedCallbacks() {
    if (!_onMetricChangedCallbackSet && !_noOnMetricsChangedHook) {
      _onMetricChangedCallbackSet = true;
      if (_Logger.logging) {
        _Logger.log(chalk.color.cornflowerblue(
            'setupViewsOnMetricChangedCallbacks() called and BEING SET UP usePlatformDipatcherOnMetricsChanged=$_usePlatformDipatcherOnMetricsChanged'));
      }
      if (_usePlatformDipatcherOnMetricsChanged) {
        // Just use platformDispatcher instance
        final existedBeforeUsOnMetricsChanged =
            WidgetsBinding.instance.platformDispatcher.onMetricsChanged;
        WidgetsBinding.instance.platformDispatcher.onMetricsChanged = () {
          if (_Logger.hookLogging) {
            _Logger.log(
                'CustomMouseCursor.onMetricsChanged() SINGLE instance.platformDispatcher() version!!!!! existedBeforeUsOnMetricsChanged=$existedBeforeUsOnMetricsChanged');
          }
          if (existedBeforeUsOnMetricsChanged != null) {
            existedBeforeUsOnMetricsChanged.call();
          }
          onMetricsChanged();
        };
      } else {
        // TODO: tmm  properly develop/test this once multiple windows/views is implemented in flutter
        // put the callback on ALL views
        for (final view in WidgetsBinding.instance.platformDispatcher.views) {
          final existedBeforeUsOnMetricsChanged =
              view.platformDispatcher.onMetricsChanged;
          view.platformDispatcher.onMetricsChanged = () {
            if (_Logger.hookLogging) {
              _Logger.log(
                  'CustomMouseCursor.onMetricsChanged() view[].platformdispatcher.onMetricsChanged() !!!!! existedBeforeUsOnMetricsChanged=$existedBeforeUsOnMetricsChanged');
              _Logger.log(
                  'View is DPR ${view.devicePixelRatio}   view.viewId=${view.viewId}');
            }
            if (existedBeforeUsOnMetricsChanged != null) {
              existedBeforeUsOnMetricsChanged.call();
            }
            onMetricsChanged();
          };
        }
      }
    }
  }

  static math.Random? randomGenerator; 
  
  /// Generate a 16 digit random key to use for cursor's key on non web platforms.
  static String generateUniqueKey() {
    // md5 seemed overkill, replaced with random key.. //return md5.convert(input).toString();

    // generate a safe/random unique 16 digit id for the cursor
    // THIS IS A QUICK HACKED version..
    // (add [generateUniqueKeysGenerated] count so we get a new seed even if we somehow are still on the 
    //  same microsecond clock time
    randomGenerator ??= math.Random(DateTime.now().microsecond);

    const String hexDigits = "0123456789abcdef";
    final uuid = List<String>.filled(16, '');

    for (int i = 0; i < 16; i++) {
      final int hexPos = randomGenerator!.nextInt(16);
      uuid[i] = hexDigits.substring(hexPos, hexPos + 1);
    }

    final buffer = StringBuffer();
    buffer.writeAll(uuid);
    return buffer.toString();
  }

  /// Converts the uiImage to a Uint8List in either BGRA format for windows or to
  /// PNG format for all other platforms.
  static Future<Uint8List> _getImageBufferInPlatformSpecificFormat(
      ui.Image uiImage) async {
    if (!kIsWeb && Platform.isWindows) {
      // we need to re-encode as BGRA
      return await _getBytesAsBGRAFromImage(uiImage);
    } else {
      // on all other platforms we ENSURE the image buffer is PNG by re-encoding
      final byteData = await uiImage.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw ('Error converting ui.Image $uiImage to PNG format using .toByteData() ${kIsWeb ? '- Known error when using HTML web renderer - Use canvaskit' : ''}');
      }
      return byteData.buffer.asUint8List();
    }
  }

  /// Returns Uint8List of the ui.Image's pixels in BGRA format
  static Future<Uint8List> _getBytesAsBGRAFromImage(ui.Image image) async {
    int width = image.width;
    int height = image.height;
    final rgbaBD = await image.toByteData(format: ImageByteFormat.rawRgba);
    final rgba = rgbaBD?.buffer.asUint8List();
    return _getRGBABytesAsBGRA(rgba!, width, height);
  }

  /// Convert RGBA formmated Uint8List into BGRA format.
  /// (This format is needed for creating cursors on windows platform)
  static Uint8List _getRGBABytesAsBGRA(Uint8List rgba, int width, int height) {
    final length = width * height * 4;
    assert(rgba.lengthInBytes == length && rgba.lengthInBytes % 4 == 0);
    final bgra = Uint8List(length);
    for (var i = 0; i < length; i += 4) {
      bgra[i + 0] = rgba[i + 2];
      bgra[i + 1] = rgba[i + 1];
      bgra[i + 2] = rgba[i + 0];
      bgra[i + 3] = rgba[i + 3];
    }
    return bgra;
  }

  /// Creates am image from the specified icon.  This is essentially identical parameters
  /// to the Icon() flutter widget but creates a ui.Image instead.
  static ui.Image _createImageFromIconSync(IconData icon,
      {double size = 32,
      Color color = Colors.black,
      double? iconFill,
      double? iconWeight,
      double? iconGrade,
      double? iconOpticalSize,
      List<Shadow>? shadows}) {
    // ICARUS PATCH: rasterize the glyph at [superSample]x the requested size
    // and downscale with high-quality filtering. Tiny cursor bitmaps rendered
    // directly at their final size look jagged on every platform;
    // supersampling gives smooth edges at any DPR.
    const double superSample = 4.0;
    final double renderSize = size * superSample;
    final PictureRecorder recorder = PictureRecorder();
    final Canvas canvas = Canvas(recorder);

    final textSpan = TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        fontVariations: <FontVariation>[
          if (iconFill != null) FontVariation('FILL', iconFill),
          if (iconWeight != null) FontVariation('wght', iconWeight),
          if (iconGrade != null) FontVariation('GRAD', iconGrade),
          if (iconOpticalSize != null) FontVariation('opsz', iconOpticalSize),
        ],
        inherit: false,
        color: color,
        fontSize: renderSize,
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
        shadows: shadows
            ?.map((shadow) => Shadow(
                  color: shadow.color,
                  offset: shadow.offset * superSample,
                  blurRadius: shadow.blurRadius * superSample,
                ))
            .toList(),
      ),
    );

    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(canvas, Offset.zero);

    final Picture picture = recorder.endRecording();
    late final ui.Image largeImage;
    try {
      largeImage = picture.toImageSync(
        renderSize.ceil(),
        renderSize.ceil(),
      );
    } finally {
      picture.dispose();
    }

    final PictureRecorder downscaleRecorder = PictureRecorder();
    final Canvas downscaleCanvas = Canvas(downscaleRecorder);
    downscaleCanvas.drawImageRect(
      largeImage,
      Rect.fromLTWH(
          0, 0, largeImage.width.toDouble(), largeImage.height.toDouble()),
      Rect.fromLTWH(0, 0, size, size),
      Paint()..filterQuality = FilterQuality.high,
    );
    final Picture downscaledPicture = downscaleRecorder.endRecording();
    late final ui.Image uiimage;
    try {
      uiimage = downscaledPicture.toImageSync(
        size.ceil(),
        size.ceil(),
      );
    } finally {
      downscaledPicture.dispose();
      largeImage.dispose();
    }
    return uiimage;
  }

  /// Decode a ARGB Uint8List buffer (that is assumed to be PNG ENCODED) and
  /// possibly scale it as well (if [rescaleRatioRequiredForImage]!=1.0) during the
  /// decoding process.
  static Future<ui.Image> _createUIImageFromPNGUint8ListBufferAndPossiblyScale(
      Uint8List rawUint8,
      {rescaleRatioRequiredForImage = 1.0}) async {
    // nonscaled case just use decodeImageFromList()
    if (rescaleRatioRequiredForImage == 1.0) {
      return await decodeImageFromList(rawUint8);
    }

    // decode and scale - new/non deprecated version
    final ui.Codec codec = await PaintingBinding.instance
        .instantiateImageCodecWithSize(
            await ImmutableBuffer.fromUint8List(rawUint8),
            getTargetSize: rescaleRatioRequiredForImage == 1.0
                ? null
                : (int width, int height) {
                    return TargetImageSize(
                        width: (width * rescaleRatioRequiredForImage).round(),
                        height:
                            (height * rescaleRatioRequiredForImage).round());
                  });
    final ui.FrameInfo frameInfo = await codec.getNextFrame();
    return frameInfo.image;
  }
}

class _CustomMouseCursorSession extends MouseCursorSession {
  _CustomMouseCursorSession(CustomMouseCursor super.cursor, super.device);

  @override
  CustomMouseCursor get cursor => super.cursor as CustomMouseCursor;

  @override
  Future<void> activate() async {
    if (kIsWeb) {
      // for the web the cursor key is a CSS cursor data-uri definition
      return SystemChannels.mouseCursor.invokeMethod<void>(
        'activateSystemCursor',
        <String, dynamic>{
          'device': device,
          'kind': cursor.key,
        },
      );
    } else {
      if (cursor.isValid) {
        await _CustomMouseCursorPlatformInterface.setSystemCursor(cursor.key);
      } else {
        throw ('An attempt to use a CustomMouseCursor object (${cursor.key}) which previosuly had dispose() called.');
      }
    }
  }

  @override
  void dispose() {}
}

/// The platform interface either the flutter engine (windows) or our platform plugin channels (for macOS and linux).
/// This plugin's platform channel accepts commands in the identical format as the flutter engine's built in
/// windows platform implementation.
class _CustomMouseCursorPlatformInterface {
  static const createCursorKey = "createCustomCursor";
  static const setCursorMethod = "setCustomCursor";
  static const deleteCursorMethod = "deleteCustomCursor";

  _CustomMouseCursorPlatformInterface._();

  static Future<String> registerCursor(
    String name,
    Uint8List buffer,
    int width,
    int height,
    double hotX,
    double hotY, {
    double scale = 1.0,
  }) async {
    if (!scale.isFinite || scale <= 0) {
      throw ArgumentError.value(
          scale, 'scale', 'must be a finite, positive devicePixelRatio');
    }
    final cursorName = await _getMethodChannel()
        .invokeMethod<String>(_getMethod(createCursorKey), <String, dynamic>{
      'name': name,
      'buffer': buffer,
      'width': width,
      'height': height,
      'hotX': hotX,
      'hotY': hotY,
      // ICARUS PATCH: bitmap-pixels per logical point. Read by the macOS
      // plugin to set the NSImage point size; ignored on Windows/Linux.
      'scale': scale,
    });
    if (cursorName == null) {
      throw StateError(
          'The platform failed to create custom cursor "$name" (the native '
          'side returned null; the image data may be undecodable).');
    }
    assert(cursorName == name);
    return cursorName;
  }

  static Future<void> deleteCursor(String name) async {
    await _getMethodChannel()
        .invokeMethod(_getMethod(deleteCursorMethod), {"name": name});
  }

  static Future<void> setSystemCursor(String name) async {
    await _getMethodChannel()
        .invokeMethod(_getMethod(setCursorMethod), {"name": name});
  }

  static MethodChannel _getMethodChannel() {
    if (Platform.isWindows) {
      return SystemChannels.mouseCursor;
    } else {
      return const MethodChannel('custom_mouse_cursor');
    }
  }

  static String _getMethod(String method) {
    if (Platform.isWindows) {
      return "$method/windows";
    } else {
      return method;
    }
  }
}

enum CustomMouseCursorCreationType { exactasset, asset, image, icon }

/// This class is used to remember the parameters originally passed to icon() method so regeneration
/// of the icon based cursor's image is possible when the devicePixelRatio changes.
class _CustomMouseCursorFromIconOriginInfo {
  _CustomMouseCursorFromIconOriginInfo({
    required this.icon,
    required this.sizeInLogicalPixels,
    required this.hotXInLogicalPixels,
    required this.hotYInLogicalPixels,
    required this.fill,
    required this.weight,
    required this.opticalSize,
    required this.grade,
    required this.color,
    required this.shadows,
  });
  final double sizeInLogicalPixels;
  final int hotXInLogicalPixels;
  final int hotYInLogicalPixels;
  final IconData icon;
  final double? fill;
  final double? weight;
  final double? grade;
  final double? opticalSize;
  final Color color;
  final List<Shadow>? shadows;
}

/// This is used to cache information about images used by already created cursors for a specific
/// DevicePixelRatio.  This allows us to skip re-loading/creation of bitmaps for
/// a given DPR when the flutter window moves between different DPR screens.
/// Instead the system cursor can be regenerated from the cached bitmap data within [imageBuffer].
/// On the web platform this also caches the image's generated [base64ImageDataUri]
/// so that it can be re-used when generating web cursors which support additional devicePixelRatios.
class _CustomMouseCursorDPRBitmapCache {
  const _CustomMouseCursorDPRBitmapCache(this.imageBuffer,
      this.base64ImageDataUri, this.width, this.height, this.hotX, this.hotY);
  final Uint8List imageBuffer;
  final String? base64ImageDataUri;
  final int width;
  final int height;
  final int hotX;
  final int hotY;
}

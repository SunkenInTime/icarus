import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

class CoordinateSystem {
  // System parameters

  CoordinateSystem._({required Size playAreaSize})
      : _playAreaSize = playAreaSize;

  final Size _playAreaSize;
  Size get playAreaSize => _playAreaSize;

  static const Size screenShotSize = Size(1920, 1080);
  bool isScreenshot = false;

  void setIsScreenshot(bool value) {
    isScreenshot = value;
  }

  /// The coordinates of the canvas on screen, set by that canvas as it lays
  /// out. A screen without a canvas must not set them: every item, lineup
  /// line and stroke on the canvas converts through them. Until a canvas has
  /// laid out, the capture size stands in, so a strategy can load before its
  /// canvas is on screen.
  static CoordinateSystem _instance =
      CoordinateSystem._(playAreaSize: screenShotSize);

  // Use screenshot dimensions when isScreenshot is true; otherwise use play area size
  Size get _effectiveSize => isScreenshot ? screenShotSize : _playAreaSize;

  Size get effectiveSize => _effectiveSize;
  // The normalized coordinate space will maintain this aspect ratio
  static const double defaultMapAspectRatio = 1.24;
  final double normalizedHeight = worldHeight;
  static const double worldHeight = 1000.0;
  final double mapAspectRatio = defaultMapAspectRatio;
  final double worldAspectRatio = 16 / 9;

  /// Placed object data is always authored in the attack-side world.
  ///
  /// Defense is the same world rotated 180 degrees. Keeping that projection
  /// here makes the conversion reversible and keeps side changes out of saved
  /// positions.
  Offset positionForSide({
    required Offset canonicalPosition,
    required Offset reflectionOffset,
    required bool isAttack,
  }) {
    if (isAttack) return canonicalPosition;
    return Offset(
      worldNormalizedWidth - canonicalPosition.dx - reflectionOffset.dx,
      normalizedHeight - canonicalPosition.dy - reflectionOffset.dy,
    );
  }

  Offset positionFromSide({
    required Offset sidePosition,
    required Offset reflectionOffset,
    required bool isAttack,
  }) {
    return positionForSide(
      canonicalPosition: sidePosition,
      reflectionOffset: reflectionOffset,
      isAttack: isAttack,
    );
  }

  Offset screenPositionForSide({
    required Offset attackScreenPosition,
    required Offset reflectionOffset,
    required bool isAttack,
  }) {
    if (isAttack) return attackScreenPosition;
    return Offset(
      _effectiveSize.width - attackScreenPosition.dx - reflectionOffset.dx,
      _effectiveSize.height - attackScreenPosition.dy - reflectionOffset.dy,
    );
  }

  Offset screenPositionFromSide({
    required Offset sideScreenPosition,
    required Offset reflectionOffset,
    required bool isAttack,
  }) {
    return screenPositionForSide(
      attackScreenPosition: sideScreenPosition,
      reflectionOffset: reflectionOffset,
      isAttack: isAttack,
    );
  }

  double rotationForSide(double canonicalRotation, {required bool isAttack}) {
    return isAttack ? canonicalRotation : canonicalRotation + math.pi;
  }

  double rotationFromSide(double sideRotation, {required bool isAttack}) {
    return isAttack ? sideRotation : sideRotation - math.pi;
  }

  double get mapNormalizedWidth => normalizedHeight * mapAspectRatio;
  double get worldNormalizedWidth => normalizedHeight * worldAspectRatio;
  double get mapPaddingNormalizedX =>
      (worldNormalizedWidth - mapNormalizedWidth) / 2;

  /// The coordinates of a play area this size, without making them the
  /// canvas's: for checking where a canvas should have drawn something.
  factory CoordinateSystem.forSize(Size playAreaSize) =>
      CoordinateSystem._(playAreaSize: playAreaSize);

  factory CoordinateSystem({required Size playAreaSize}) {
    _instance = CoordinateSystem._(playAreaSize: playAreaSize);
    return _instance;
  }

  /// The coordinates every capture draws in: 1920×1080, always in screenshot
  /// mode. A capture gets its own so that nothing the editor does meanwhile
  /// (a re-layout replacing [instance], a resize, a side switch) can leave
  /// the editor's coordinates in screenshot mode, or the capture's in the
  /// editor's.
  static final CoordinateSystem _capture =
      CoordinateSystem._(playAreaSize: screenShotSize)..isScreenshot = true;

  static const _captureZoneKey = #icarusCaptureCoordinates;

  static Zone? _lastZone;
  static bool _lastZoneIsCapture = false;

  /// Runs [capture] in the capture's coordinates: inside it, and in every
  /// Future and timer it starts, [instance] is the capture's. The editor,
  /// whose frames run outside it, keeps its own throughout.
  static Future<T> runInCapture<T>(Future<T> Function() capture) =>
      runZoned(capture, zoneValues: {_captureZoneKey: _capture});

  /// The coordinates of whatever is drawing: a capture's inside
  /// [runInCapture], the editor's everywhere else.
  static CoordinateSystem get instance {
    // Read on every conversion while drawing, so the zone lookup is skipped
    // for the zone that asked last.
    final zone = Zone.current;
    if (!identical(zone, _lastZone)) {
      _lastZone = zone;
      _lastZoneIsCapture = zone[_captureZoneKey] is CoordinateSystem;
    }
    if (_lastZoneIsCapture) return _capture;
    return _instance;
  }

  Offset screenToCoordinate(Offset screenPoint) {
    final double normalizedX =
        (screenPoint.dx / _effectiveSize.width) * worldNormalizedWidth;
    final double normalizedY =
        (screenPoint.dy / _effectiveSize.height) * normalizedHeight;

    return Offset(normalizedX, normalizedY);
  }

  Offset coordinateToScreen(Offset coordinates) {
    final double screenX =
        (coordinates.dx / worldNormalizedWidth) * (_effectiveSize.width);
    final double screenY =
        (coordinates.dy / normalizedHeight) * (_effectiveSize.height);

    return Offset(screenX, screenY);
  }

  double worldWidthToScreen(double worldWidth) {
    return (worldWidth / worldNormalizedWidth) * _effectiveSize.width;
  }

  double worldHeightToScreen(double worldHeight) {
    return (worldHeight / normalizedHeight) * _effectiveSize.height;
  }

  double screenWidthToWorld(double screenWidth) {
    return (screenWidth / _effectiveSize.width) * worldNormalizedWidth;
  }

  double screenHeightToWorld(double screenHeight) {
    return (screenHeight / _effectiveSize.height) * normalizedHeight;
  }

  Size worldSizeToScreen(Size worldSize) {
    return Size(
      worldWidthToScreen(worldSize.width),
      worldHeightToScreen(worldSize.height),
    );
  }

  Size screenSizeToWorld(Size screenSize) {
    return Size(
      screenWidthToWorld(screenSize.width),
      screenHeightToWorld(screenSize.height),
    );
  }

  /// Converts a legacy widget-space offset into normalized world units.
  ///
  /// Most draggable widget dimensions are authored against [_baseHeight],
  /// while persisted positions and map geometry use [normalizedHeight].
  Offset virtualOffsetToWorld(Offset virtualOffset) {
    final screenOffset = virtualOffset.scale(_scaleFactor, _scaleFactor);
    return Offset(
      screenWidthToWorld(screenOffset.dx),
      screenHeightToWorld(screenOffset.dy),
    );
  }

  double virtualLengthToWorld(double virtualLength) {
    return screenHeightToWorld(scale(virtualLength));
  }

  Offset worldOffsetToScreen(Offset worldOffset) {
    return Offset(
      worldWidthToScreen(worldOffset.dx),
      worldHeightToScreen(worldOffset.dy),
    );
  }

  final double _baseHeight = _virtualBaseHeight;
  static const double _virtualBaseHeight = 831.0;

  /// [virtualOffsetToWorld] without an instance: the conversion is the same
  /// at every screen size, so code that only converts sizes needn't wait for
  /// a canvas to lay out.
  static Offset virtualToWorld(Offset virtualOffset) =>
      virtualOffset * (worldHeight / _virtualBaseHeight);

  /// [virtualLengthToWorld] without an instance.
  static double virtualLengthInWorld(double virtualLength) =>
      virtualLength * (worldHeight / _virtualBaseHeight);
  // Get the scale factor based on screen height
  double get _scaleFactor => _effectiveSize.height / _baseHeight;

  double get scaleFactor => _scaleFactor;
  // Scale any dimension based on height
  double scale(double size) => (size * _scaleFactor);

  double normalize(double value) => (value / _scaleFactor);
  // Scale a size maintaining aspect ratio
  Size scaleSize(Size size) =>
      Size(size.width * _scaleFactor, size.height * _scaleFactor);

  Offset convertOldCoordinateToNew(Offset oldCoordinate) {
    return oldCoordinate;
  }

  // Convenience method to wrap a widget with scaled dimensions
  Widget scaleWidget({required Widget child, required Size originalSize}) {
    Size scaledSize = scaleSize(originalSize);
    return SizedBox(
      width: scaledSize.width,
      height: scaledSize.height,
      child: child,
    );
  }

  /// How close to the edge, in world units, an item's anchor can be dropped
  /// before [isOutOfBounds] deletes it.
  static const double dropEdge = 10;

  bool isOutOfBounds(Offset offset) {
    return offset.dx > worldNormalizedWidth - dropEdge ||
        offset.dy > normalizedHeight - dropEdge ||
        offset.dx < 0 + dropEdge ||
        offset.dy < 0 + dropEdge;
  }

  /// Whether an item saved at [position], whose dot sits [anchor] from there,
  /// is off the map. The anchor is in drawing units and the position in world
  /// units, so it is converted first: added as it is, it falls short of the
  /// dot, and an item with its dot on the map reads as off it.
  bool isAnchorOutOfBounds(Offset position, Offset anchor) {
    return isOutOfBounds(position + virtualToWorld(anchor));
  }

  /// Whether a picture or text box saved at top-left [position], [screenSize]
  /// big on the canvas, is off the map. It has no dot, so it goes once its
  /// top-left and its middle have both left: the top-left alone would delete
  /// a box hanging over the top edge, the middle alone one hanging over the
  /// bottom edge, with most of it still on the map.
  bool isBoxOutOfBounds(Offset position, Size screenSize) {
    final middle = screenSizeToWorld(screenSize).center(position);
    return isOutOfBounds(position) && isOutOfBounds(middle);
  }

  /// Where an item dropped at [position], whose dot sits [anchor] from
  /// there, lands, when [view] is the part of the canvas on screen (see
  /// [showing]). Dropped off the map, it stays where it was dropped, for the
  /// drop to delete it. Otherwise its dot shows: the map runs on under the
  /// sidebar and past the window, and an item left there is hard to find.
  Offset anchoredDrop(
    Offset position,
    Offset anchor,
    Rect? view, {
    required bool isAttack,
  }) {
    if (isAnchorOutOfBounds(position, anchor)) return position;
    return showing(position, virtualToWorld(anchor), view, isAttack: isAttack);
  }

  /// [anchoredDrop] for a picture or text box, [screenSize] big on the
  /// canvas, which has no dot: its middle shows.
  Offset boxDrop(
    Offset position,
    Size screenSize,
    Rect? view, {
    required bool isAttack,
  }) {
    if (isBoxOutOfBounds(position, screenSize)) return position;
    final middle = screenSizeToWorld(screenSize).center(Offset.zero);
    return showing(position, middle, view, isAttack: isAttack);
  }

  /// [position] moved just far enough that the point [at] from it is in
  /// [view], a little in from its edge so it can be grabbed. [position] and
  /// [at] are in world units, saved attack side up; [view] is in canvas
  /// pixels, as drawn on the side shown. Without one it doesn't move.
  Offset showing(
    Offset position,
    Offset at,
    Rect? view, {
    required bool isAttack,
  }) {
    final seen = inSight(view, isAttack: isAttack);
    if (seen == null) return position;
    final point = position + at;
    final shown = Offset(
      point.dx.clamp(seen.left, seen.right),
      point.dy.clamp(seen.top, seen.bottom),
    );
    return position + (shown - point);
  }

  /// Where [showing] keeps a point, in world units saved attack side up:
  /// inside [view], a little in from its edge. [view] is in canvas pixels, as
  /// drawn on the side shown. Null without one.
  Rect? inSight(Rect? view, {required bool isAttack}) {
    if (view == null || view.isEmpty) return null;
    var seen = Rect.fromPoints(
      screenToCoordinate(view.topLeft),
      screenToCoordinate(view.bottomRight),
    );
    if (!isAttack) {
      // Defense draws the attack-side world turned half a turn.
      seen = Rect.fromLTRB(
        worldNormalizedWidth - seen.right,
        normalizedHeight - seen.bottom,
        worldNormalizedWidth - seen.left,
        normalizedHeight - seen.top,
      );
    }
    return _deflateUpTo(seen, dropEdge + 2);
  }

  /// [rect] deflated by [by], or down to its middle line along an axis
  /// narrower than that.
  static Rect _deflateUpTo(Rect rect, double by) {
    final x = math.min(by, rect.width / 2);
    final y = math.min(by, rect.height / 2);
    return Rect.fromLTRB(
      rect.left + x,
      rect.top + y,
      rect.right - x,
      rect.bottom - y,
    );
  }
}

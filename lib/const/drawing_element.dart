import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/bounding_box.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/json_converters.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/traversal_speed.dart';
import 'package:json_annotation/json_annotation.dart';

part "drawing_element.g.dart";

abstract class DrawingElement {
  @JsonKey(
    readValue: _readDrawingColorJsonValue,
    fromJson: _drawingColorValueFromJson,
    toJson: _drawingColorValueToJson,
  )
  final int colorValue;
  @JsonKey(defaultValue: Settings.defaultStrokeThickness)
  final double thickness;
  final bool isDotted;
  final bool hasArrow;
  final String id;
  BoundingBox? boundingBox;

  @JsonKey(includeFromJson: false, includeToJson: false)
  Color get color => Color(colorValue);

  DrawingElement({
    required this.colorValue,
    this.thickness = Settings.defaultStrokeThickness,
    this.boundingBox,
    required this.isDotted,
    required this.hasArrow,
    required this.id,
  });

  static int getIndexByID(String id, List<DrawingElement> elements) {
    return elements.indexWhere(
      (element) => element.id == id,
    );
  }
}

Object? _readDrawingColorJsonValue(Map<dynamic, dynamic> json, String key) {
  return json[key] ?? json['color'];
}

int _drawingColorValueFromJson(Object? json) {
  if (json is int) return json;
  if (json is num) return json.toInt();
  if (json is String) {
    return const ColorConverter().fromJson(json).toARGB32();
  }
  throw ArgumentError.value(json, 'json', 'Unsupported drawing color value');
}

int _drawingColorValueToJson(int colorValue) => colorValue;

class Line extends DrawingElement with HiveObjectMixin {
  final Offset lineStart;
  Offset lineEnd;
  final bool showTraversalTime;
  final TraversalSpeedProfile traversalSpeedProfile;

  Line({
    required this.lineStart,
    required this.lineEnd,
    Color? color,
    int? colorValue,
    super.thickness = Settings.defaultStrokeThickness,
    super.boundingBox,
    required super.isDotted,
    required super.hasArrow,
    required super.id,
    this.showTraversalTime = false,
    this.traversalSpeedProfile = TraversalSpeed.defaultProfile,
  })  : assert(
          color != null || colorValue != null,
          'Either color or colorValue is required.',
        ),
        super(colorValue: colorValue ?? color!.toARGB32());

  void updateEndPoint(Offset endPoint) {
    lineEnd = endPoint;
  }

  Line copyWith({
    Offset? lineStart,
    Offset? lineEnd,
    Color? color,
    int? colorValue,
    double? thickness,
    BoundingBox? boundingBox,
    bool? isDotted,
    bool? hasArrow,
    String? id,
    bool? showTraversalTime,
    TraversalSpeedProfile? traversalSpeedProfile,
  }) {
    return Line(
      lineStart: lineStart ?? this.lineStart,
      lineEnd: lineEnd ?? this.lineEnd,
      colorValue: colorValue ?? color?.toARGB32() ?? this.colorValue,
      thickness: thickness ?? this.thickness,
      boundingBox: boundingBox ?? this.boundingBox,
      isDotted: isDotted ?? this.isDotted,
      hasArrow: hasArrow ?? this.hasArrow,
      id: id ?? this.id,
      showTraversalTime: showTraversalTime ?? this.showTraversalTime,
      traversalSpeedProfile:
          traversalSpeedProfile ?? this.traversalSpeedProfile,
    );
  }
}

class RectangleDrawing extends DrawingElement with HiveObjectMixin {
  final Offset start;
  Offset end;

  RectangleDrawing({
    required this.start,
    required this.end,
    Color? color,
    int? colorValue,
    super.thickness = Settings.defaultStrokeThickness,
    super.boundingBox,
    required super.isDotted,
    required super.hasArrow,
    required super.id,
  })  : assert(
          color != null || colorValue != null,
          'Either color or colorValue is required.',
        ),
        super(colorValue: colorValue ?? color!.toARGB32());

  void updateEndPoint(Offset endPoint) {
    end = endPoint;
  }

  Rect get normalizedRect => Rect.fromLTRB(
        start.dx < end.dx ? start.dx : end.dx,
        start.dy < end.dy ? start.dy : end.dy,
        start.dx > end.dx ? start.dx : end.dx,
        start.dy > end.dy ? start.dy : end.dy,
      );
}

class EllipseDrawing extends DrawingElement with HiveObjectMixin {
  final Offset start;
  Offset end;

  EllipseDrawing({
    required this.start,
    required this.end,
    Color? color,
    int? colorValue,
    super.thickness = Settings.defaultStrokeThickness,
    super.boundingBox,
    required super.isDotted,
    required super.hasArrow,
    required super.id,
  })  : assert(
          color != null || colorValue != null,
          'Either color or colorValue is required.',
        ),
        super(colorValue: colorValue ?? color!.toARGB32());

  void updateEndPoint(Offset endPoint) {
    end = endPoint;
  }

  Rect get normalizedRect => Rect.fromLTRB(
        start.dx < end.dx ? start.dx : end.dx,
        start.dy < end.dy ? start.dy : end.dy,
        start.dx > end.dx ? start.dx : end.dx,
        start.dy > end.dy ? start.dy : end.dy,
      );
}

@JsonSerializable()
class FreeDrawing extends DrawingElement with HiveObjectMixin {
  FreeDrawing({
    List<Offset>? listOfPoints,
    Path? path,
    Color? color,
    int? colorValue,
    super.thickness = Settings.defaultStrokeThickness,
    super.boundingBox,
    required super.isDotted,
    required super.hasArrow,
    required super.id,
    this.showTraversalTime = false,
    this.traversalSpeedProfile = TraversalSpeed.defaultProfile,
    double? cachedPolylineLengthUnits,
  })  : listOfPoints = listOfPoints ?? [],
        assert(
          color != null || colorValue != null,
          'Either color or colorValue is required.',
        ),
        _path = path ?? Path(),
        cachedPolylineLengthUnits = cachedPolylineLengthUnits ??
            _computePolylineLength(listOfPoints ?? []),
        super(colorValue: colorValue ?? color!.toARGB32());

  @OffsetListConverter()
  List<Offset> listOfPoints = [];

  @JsonKey(defaultValue: false)
  final bool showTraversalTime;

  @JsonKey(defaultValue: TraversalSpeed.defaultProfile)
  final TraversalSpeedProfile traversalSpeedProfile;

  @JsonKey(includeFromJson: false, includeToJson: false)
  double cachedPolylineLengthUnits;

  @JsonKey(includeFromJson: false, includeToJson: false)
  Path _path = Path();

  factory FreeDrawing.fromJson(Map<String, dynamic> json) =>
      _$FreeDrawingFromJson(json);

  // @override
  Map<String, dynamic> toJson() => _$FreeDrawingToJson(this);

  void updatePath(Path newPath) {
    _path = newPath;
  }

  void appendPoint(Offset point) {
    if (listOfPoints.isNotEmpty) {
      cachedPolylineLengthUnits += (point - listOfPoints.last).distance;
    }
    listOfPoints.add(point);
  }

  void replacePoints(List<Offset> points) {
    listOfPoints = points;
    recomputeCachedPolylineLength();
  }

  void recomputeCachedPolylineLength() {
    cachedPolylineLengthUnits = _computePolylineLength(listOfPoints);
  }

  static double _computePolylineLength(List<Offset> points) {
    if (points.length < 2) return 0.0;

    double totalLength = 0.0;
    for (int i = 0; i < points.length - 1; i++) {
      totalLength += (points[i + 1] - points[i]).distance;
    }
    return totalLength;
  }

  void rebuildPath(CoordinateSystem coordinateSystem) {
    if (listOfPoints.length < 2) {
      if (listOfPoints.isEmpty) {
        _path = Path();
        return;
      }

      final path = Path();
      final screenPoint = coordinateSystem.coordinateToScreen(listOfPoints[0]);
      final dotRadius = (coordinateSystem.scale(thickness * 0.25))
          .clamp(1.0, coordinateSystem.scale(2.0))
          .toDouble();

      path.addOval(Rect.fromCircle(center: screenPoint, radius: dotRadius));
      _path = path;

      return;
    }

    final path = Path();
    final screenPoints = listOfPoints
        .map((p) => coordinateSystem.coordinateToScreen(p))
        .toList();

    // Move to first point
    path.moveTo(screenPoints[0].dx, screenPoints[0].dy);

    Offset? previousPoint;
    for (int i = 0; i < screenPoints.length; i++) {
      final current = screenPoints[i];

      if (i != 0 && previousPoint != null) {
        double midX = (previousPoint.dx + current.dx) / 2;
        double midY = (previousPoint.dy + current.dy) / 2;
        if (i == 1) {
          path.lineTo(midX, midY);
        } else {
          path.quadraticBezierTo(
              previousPoint.dx, previousPoint.dy, midX, midY);
        }
      }
      previousPoint = current;
    }

    path.lineTo(previousPoint!.dx, previousPoint.dy);

    _path = path;
  }

  FreeDrawing copyWith({
    List<Offset>? listOfPoints,
    Path? path,
    Color? color,
    int? colorValue,
    double? thickness,
    BoundingBox? boundingBox,
    bool? isDotted,
    bool? hasArrow,
    String? id,
    bool? showTraversalTime,
    TraversalSpeedProfile? traversalSpeedProfile,
    double? cachedPolylineLengthUnits,
  }) {
    return FreeDrawing(
      colorValue: colorValue ?? color?.toARGB32() ?? this.colorValue,
      thickness: thickness ?? this.thickness,
      listOfPoints: listOfPoints ?? this.listOfPoints,
      path: path ?? _path,
      boundingBox: boundingBox ?? this.boundingBox,
      isDotted: isDotted ?? this.isDotted,
      hasArrow: hasArrow ?? this.hasArrow,
      id: id ?? this.id,
      showTraversalTime: showTraversalTime ?? this.showTraversalTime,
      traversalSpeedProfile:
          traversalSpeedProfile ?? this.traversalSpeedProfile,
      cachedPolylineLengthUnits:
          cachedPolylineLengthUnits ?? this.cachedPolylineLengthUnits,
    );
  }

  @override
  String toString() {
    String ouptut = "";

    for (Offset offset in listOfPoints) {
      ouptut += "${offset.toString()}, ";
    }
    return ouptut;
  }

  List<Offset> pathSmoothing(List<Offset> points) {
    final List<Offset> smoothPoints = [];
    if (points.length < 2) {
      return points;
    }

    // Add the first point
    smoothPoints.add(points[0]);

    for (int i = 0; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];

      // Add more intermediate points with more extreme weighting
      // This creates 5 points between each original pair
      final q1 = Offset(
        0.9 * p0.dx + 0.1 * p1.dx,
        0.9 * p0.dy + 0.1 * p1.dy,
      );
      final q2 = Offset(
        0.7 * p0.dx + 0.3 * p1.dx,
        0.7 * p0.dy + 0.3 * p1.dy,
      );
      final q3 = Offset(
        0.5 * p0.dx + 0.5 * p1.dx,
        0.5 * p0.dy + 0.5 * p1.dy,
      );
      final q4 = Offset(
        0.3 * p0.dx + 0.7 * p1.dx,
        0.3 * p0.dy + 0.7 * p1.dy,
      );
      final q5 = Offset(
        0.1 * p0.dx + 0.9 * p1.dx,
        0.1 * p0.dy + 0.9 * p1.dy,
      );

      smoothPoints.add(q1);
      smoothPoints.add(q2);
      smoothPoints.add(q3);
      smoothPoints.add(q4);
      smoothPoints.add(q5);
    }

    // Add the last point
    smoothPoints.add(points.last);

    return smoothPoints;
  }
}

extension FreeDrawingx on FreeDrawing {
  Path get path => _path;
}

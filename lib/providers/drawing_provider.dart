import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/bounding_box.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:uuid/uuid.dart';

class DrawingState {
  final List<DrawingElement> elements;
  final int updateCounter; // Keep this!
  final DrawingElement? currentElement;

  DrawingState({
    required this.elements,
    this.updateCounter = 0,
    this.currentElement,
  });

  DrawingState copyWith({
    List<DrawingElement>? elements,
    int? updateCounter,
    DrawingElement? currentElement,
  }) {
    return DrawingState(
      elements: elements ?? this.elements,
      updateCounter: updateCounter ?? this.updateCounter,
      currentElement: currentElement ?? this.currentElement,
    );
  }

  //The copy with pattern does not work in this current situation because sometimes we actually need to set a null value to currentElement
  DrawingState copyWithButEvil({
    List<DrawingElement>? elements,
    int? updateCounter,
  }) {
    return DrawingState(
      elements: elements ?? this.elements,
      updateCounter: updateCounter ?? this.updateCounter,
      currentElement: null,
    );
  }

  @override
  String toString() {
    String output = "";
    for (DrawingElement element in elements) {
      if (element is FreeDrawing) {
        output += "${element.listOfPoints.toString()} \n--------------\n";
      }
    }
    return output;
  }
}

final drawingProvider =
    NotifierProvider<DrawingProvider, DrawingState>(DrawingProvider.new);

class DrawingProvider extends Notifier<DrawingState> {
  List<DrawingElement> poppedElements = [];

  @override
  DrawingState build() {
    return DrawingState(elements: []);
  }

  void undoAction(UserAction action) {
    final newElements = [...state.elements];
    try {
      switch (action.type) {
        case ActionType.addition:
          final index = DrawingElement.getIndexByID(action.id, newElements);
          poppedElements.add(newElements.removeAt(index));

        case ActionType.deletion:
          final index = DrawingElement.getIndexByID(action.id, poppedElements);
          newElements.add(poppedElements.removeAt(index));
        default:
      }
    } catch (_) {
      dev.log("Can't find index in undo action");
    }
    state = state.copyWith(elements: newElements);
    _triggerRepaint();
  }

  void redoAction(UserAction action) {
    final newElements = [...state.elements];
    try {
      switch (action.type) {
        case ActionType.addition:
          final index = DrawingElement.getIndexByID(action.id, poppedElements);
          newElements.add(poppedElements.removeAt(index));
        case ActionType.deletion:
          final index = DrawingElement.getIndexByID(action.id, newElements);
          poppedElements.add(newElements.removeAt(index));
        default:
      }
    } catch (_) {
      dev.log("Can't find index in redo action");
    }
    state = state.copyWith(elements: newElements);
    _triggerRepaint();
  }

  String toJson() {
    final List<Map<String, dynamic>> jsonList = state.elements
        .whereType<FreeDrawing>()
        .map((element) => element.toJson())
        .toList();
    return jsonEncode(jsonList);
  }

  static String objectToJson(List<DrawingElement> elements) {
    final List<Map<String, dynamic>> jsonList = elements
        .whereType<FreeDrawing>()
        .map((element) => element.toJson())
        .toList();
    return jsonEncode(jsonList);
  }

  void fromHive(List<DrawingElement> hiveDrawings) {
    final coordinateSystem = CoordinateSystem.instance;
    final newDrawings = hiveDrawings.map((drawing) {
      if (drawing is FreeDrawing) {
        drawing.rebuildPath(coordinateSystem);
      }
      return drawing;
    }).toList();

    poppedElements = [];
    state = state.copyWith(elements: newDrawings);
    _triggerRepaint();
  }

  static List<DrawingElement> fromJson(String jsonString) {
    final List<dynamic> jsonList = jsonDecode(jsonString);
    // dev.log(jsonList.toString());
    // final coordinateSystem = CoordinateSystem.instance;

    final result = jsonList.map((json) {
      try {
        final drawing = FreeDrawing.fromJson(json as Map<String, dynamic>);
        return drawing;
      } catch (e) {
        dev.log(e.toString());
        return FreeDrawing(
            color: Colors.red, isDotted: true, hasArrow: true, id: "test");
      }
    }).toList();

    return result;
  }

  void _triggerRepaint() {
    state = state.copyWith(updateCounter: (state.updateCounter + 1));
  }

  void deleteDrawing(int index) {
    if (index < 0) return;
    final newElements = [...state.elements];

    final poppedElement = newElements.removeAt(index);
    poppedElements.add(poppedElement);

    final action = UserAction(
      type: ActionType.deletion,
      id: poppedElement.id,
      group: ActionGroup.drawing,
    );
    ref.read(actionProvider.notifier).addAction(action);

    state = state.copyWith(elements: [...newElements]);
    _triggerRepaint();
  }

  void onErase(Offset mousePos) {
    final Set<int> indicesToDelete = {};

    for (final (index, drawing) in state.elements.indexed) {
      if (drawing is FreeDrawing) {
        if (drawing.boundingBox!.isWithin(mousePos)) {
          for (int i = 0; i < drawing.listOfPoints.length - 1; i++) {
            double distance = distanceToLineSegment(
                mousePos, drawing.listOfPoints[i], drawing.listOfPoints[i + 1]);

            if (distance < 100) {
              indicesToDelete.add(index);
              break;
            }
          }
        }
      }
    }

    for (int index in indicesToDelete.toList()
      ..sort((a, b) => b.compareTo(a))) {
      deleteDrawing(index);
    }
  }

  double distanceToLineSegment(Offset p, Offset a, Offset b) {
    // If a and b are the same point, just return distance to that point
    if (a == b) return (p - a).distance;

    // Calculate squared length of segment ab
    final double lengthSquared =
        (b - a).dx * (b - a).dx + (b - a).dy * (b - a).dy;

    // Calculate projection of point p onto line ab
    // t is the normalized position (0-1) along the line segment
    double t = ((p.dx - a.dx) * (b.dx - a.dx) + (p.dy - a.dy) * (b.dy - a.dy)) /
        lengthSquared;

    // Clamp t to the segment
    t = t.clamp(0.0, 1.0);

    // Calculate the closest point on the segment
    final Offset projection =
        Offset(a.dx + t * (b.dx - a.dx), a.dy + t * (b.dy - a.dy));

    // Return the distance to the closest point
    return (p - projection).distance;
  }

  // void startSimpleTap(Offset start, CoordinateSystem coordinateSystem) {
  //   if (state.currentElement != null) {
  //     dev.log(
  //         "An error occured the gesture detecture is attempting to draw while another line is active");
  //     return;
  //   }
  //   final Offset normalizedStart = coordinateSystem.screenToCoordinate(start);

  //   final id = const Uuid().v4();

  //   FreeDrawing freeDrawing = FreeDrawing(
  //     hasArrow: false,
  //     isDotted: false,
  //     color: Colors.white,
  //     boundingBox: BoundingBox(min: normalizedStart, max: normalizedStart),
  //     id: id,
  //     listOfPoints: [normalizedStart],
  //   );

  //   // Draw a visible dot in screen space so it actually renders
  //   // final radius = max(1.0, coordinateSystem.scale(2));

  //   // freeDrawing.path.addOval(Rect.fromCircle(center: start, radius: radius));

  //   state = state.copyWithButEvil(
  //     elements: [...state.elements, freeDrawing],
  //   );

  //   final action = UserAction(
  //       type: ActionType.addition,
  //       id: freeDrawing.id,
  //       group: ActionGroup.drawing);
  //   ref.read(actionProvider.notifier).addAction(action);

  //   _triggerRepaint();
  // }

  void startFreeDrawing(Offset start, CoordinateSystem coordinateSystem,
      Color activeColor, bool isDotted, bool hasArrow) {
    if (state.currentElement != null) {
      dev.log(
          "An error occured the gesture detecture is attempting to draw while another line is active");
      return;
    }
    final Offset normalizedStart = coordinateSystem.screenToCoordinate(start);

    final id = const Uuid().v4();
    FreeDrawing freeDrawing = FreeDrawing(
      hasArrow: hasArrow,
      isDotted: isDotted,
      color: activeColor,
      boundingBox: BoundingBox(min: normalizedStart, max: normalizedStart),
      id: id,
    );

    freeDrawing.path.moveTo(start.dx, start.dy);

    freeDrawing.listOfPoints.add(normalizedStart);

    state = state.copyWith(currentElement: freeDrawing);

    _triggerRepaint();
  }

  void updateFreeDrawing(Offset offset, CoordinateSystem coordinateSystem) {
    if (state.currentElement == null) return;
    final currentDrawing = (state.currentElement as FreeDrawing);
    final normalizedOffset = coordinateSystem.screenToCoordinate(offset);

    List<Offset> currentPoints = currentDrawing.listOfPoints;
    Offset lastPoint = currentPoints[currentPoints.length - 1];

    final minDistance = coordinateSystem.scale(3);
    if ((lastPoint - offset).distance < minDistance) return;

    final boundingBox =
        updateBoundingBox(currentDrawing.boundingBox!, normalizedOffset);

    currentDrawing.path.lineTo(offset.dx, offset.dy);

    currentDrawing.listOfPoints
        .add(coordinateSystem.screenToCoordinate(offset));

    currentDrawing.boundingBox = boundingBox;
    state = state.copyWith(currentElement: currentDrawing);
    _triggerRepaint();
  }

  void finishFreeDrawing(Offset? offset, CoordinateSystem coordinateSystem) {
    if (state.currentElement == null) return;

    // if (state.currentElement == null) return;
    final currentDrawing = state.currentElement as FreeDrawing;
    if (offset != null) {
      currentDrawing.listOfPoints
          .add(coordinateSystem.screenToCoordinate(offset));
    }

    FreeDrawing simplifiedDrawing = douglasPeucker(currentDrawing, 1.4);

    simplifiedDrawing.rebuildPath(coordinateSystem);

    state = state.copyWithButEvil(
      elements: [...state.elements, simplifiedDrawing],
    );

    final action = UserAction(
        type: ActionType.addition,
        id: simplifiedDrawing.id,
        group: ActionGroup.drawing);
    ref.read(actionProvider.notifier).addAction(action);

    _triggerRepaint();
  }

  BoundingBox updateBoundingBox(BoundingBox currentBox, Offset newPoint) {
    final minX = min(currentBox.min.dx, newPoint.dx);
    final minY = min(currentBox.min.dy, newPoint.dy);
    final maxX = max(currentBox.max.dx, newPoint.dx);
    final maxY = max(currentBox.max.dy, newPoint.dy);
    return BoundingBox(min: Offset(minX, minY), max: Offset(maxX, maxY));
  }

  void startLine(Offset start) {
    final listOfElements = state.elements;

    if (state.currentElement != null) {
      dev.log(
          "An error occured the gesture detecture is attempting to draw while another line is active");
      return;
    }

    // Line newLine = Line(color: Colors.white, lineStart: start, lineEnd: start);
    // listOfElements.add(newLine);

    state = state.copyWith(elements: listOfElements);
    // _indexOfCurrentEdit = listOfElements.length - 1;
    _triggerRepaint();
  }

  void updateCurrentLine(Offset endpoint) {
    final listOfElements = state.elements;
    // (listOfElements[_indexOfCurrentEdit] as Line).updateEndPoint(endpoint);

    state = state.copyWith(elements: listOfElements);
    _triggerRepaint();
  }

  void finishCurrentLine(Offset endpoint) {
    final listOfElements = state.elements;

    // (listOfElements[_indexOfCurrentEdit] as Line).updateEndPoint(endpoint);
    // _indexOfCurrentEdit = -1;

    state = state.copyWith(elements: listOfElements);
    _triggerRepaint();
  }

  void rebuildAllPaths(CoordinateSystem coordinateSystem) {
    final listOfElements = state.elements;

    for (DrawingElement drawingElement in listOfElements) {
      if (drawingElement is FreeDrawing) {
        drawingElement.rebuildPath(coordinateSystem);
      }
    }

    state = state.copyWith(elements: listOfElements);
    _triggerRepaint();
  }

  void clearAll() {
    poppedElements = [];
    state = DrawingState(elements: []);
    _triggerRepaint();
  }
}

//Yes I used AI to write the algo. I promise you I understand how it works
FreeDrawing douglasPeucker(FreeDrawing drawing, double epsilon) {
  if (drawing.listOfPoints.length < 3) {
    return drawing;
  }
  FreeDrawing newDrawing = drawing.copyWith();

  final listOfPoints = newDrawing.listOfPoints;

  // Find the point farthest from the line between the first and last points
  double maxDistance = 0;
  int index = 0;

  for (int i = 1; i < listOfPoints.length - 1; i++) {
    double distance = perpendicularDistance(
        listOfPoints[i], listOfPoints.first, listOfPoints.last);
    if (distance > maxDistance) {
      maxDistance = distance;
      index = i;
    }
  }

  // If the max distance is greater than epsilon, recursively simplify
  if (maxDistance > epsilon) {
    final leftDrawing = douglasPeucker(
        newDrawing.copyWith(listOfPoints: listOfPoints.sublist(0, index + 1)),
        epsilon);
    final rightDrawing = douglasPeucker(
        newDrawing.copyWith(
            listOfPoints: listOfPoints.sublist(index, listOfPoints.length)),
        epsilon);

    // Combine the results, removing the duplicate point at the split
    newDrawing.listOfPoints = [
      ...leftDrawing.listOfPoints
          .sublist(0, leftDrawing.listOfPoints.length - 1),
      ...rightDrawing.listOfPoints
    ];
    return newDrawing;
  } else {
    // If no point is far enough, return the endpoints
    newDrawing.listOfPoints = [listOfPoints.first, listOfPoints.last];
    return newDrawing;
  }
}

double perpendicularDistance(Offset point, Offset lineStart, Offset lineEnd) {
  double dx = lineEnd.dx - lineStart.dx;
  double dy = lineEnd.dy - lineStart.dy;

  if (dx == 0 && dy == 0) {
    // Line start and end are the same point
    return sqrt(
        pow(point.dx - lineStart.dx, 2) + pow(point.dy - lineStart.dy, 2));
  }

  double numerator = (dy * point.dx -
          dx * point.dy +
          lineEnd.dx * lineStart.dy -
          lineEnd.dy * lineStart.dx)
      .abs();
  double denominator = sqrt(dx * dx + dy * dy);

  return numerator / denominator;
}

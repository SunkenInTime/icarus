import 'dart:ui';

import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/json_converters.dart';
import 'package:json_annotation/json_annotation.dart';
part 'bounding_box.g.dart';

@JsonSerializable()
class BoundingBox extends HiveObject {
  @OffsetConverter()
  final Offset min;

  @OffsetConverter()
  final Offset max;

  BoundingBox({required this.min, required this.max});

  /// The smallest box around [points], which has at least one.
  factory BoundingBox.around(Iterable<Offset> points) {
    var left = points.first.dx, right = left;
    var top = points.first.dy, bottom = top;
    for (final point in points) {
      if (point.dx < left) left = point.dx;
      if (point.dx > right) right = point.dx;
      if (point.dy < top) top = point.dy;
      if (point.dy > bottom) bottom = point.dy;
    }
    return BoundingBox(min: Offset(left, top), max: Offset(right, bottom));
  }

  bool isWithinOrNear(Offset position, double threshold) {
    return position.dx >= min.dx - threshold &&
        position.dx <= max.dx + threshold &&
        position.dy >= min.dy - threshold &&
        position.dy <= max.dy + threshold;
  }

  Map<String, dynamic> toJson() => _$BoundingBoxToJson(this);

  factory BoundingBox.fromJson(Map<String, dynamic> json) =>
      _$BoundingBoxFromJson(json);

  @override
  String toString() {
    return 'BoundingBox(min: $min, max: $max)';
  }
}

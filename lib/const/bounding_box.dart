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

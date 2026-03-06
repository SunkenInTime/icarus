// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'bounding_box.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

BoundingBox _$BoundingBoxFromJson(Map<String, dynamic> json) => BoundingBox(
      min:
          const OffsetConverter().fromJson(json['min'] as Map<String, dynamic>),
      max:
          const OffsetConverter().fromJson(json['max'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$BoundingBoxToJson(BoundingBox instance) =>
    <String, dynamic>{
      'min': const OffsetConverter().toJson(instance.min),
      'max': const OffsetConverter().toJson(instance.max),
    };


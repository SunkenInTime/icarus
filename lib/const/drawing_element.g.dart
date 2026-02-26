// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'drawing_element.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

FreeDrawing _$FreeDrawingFromJson(Map<String, dynamic> json) => FreeDrawing(
      listOfPoints: _$JsonConverterFromJson<List<dynamic>, List<Offset>>(
          json['listOfPoints'], const OffsetListConverter().fromJson),
      color: const ColorConverter().fromJson(json['color'] as String),
      boundingBox: json['boundingBox'] == null
          ? null
          : BoundingBox.fromJson(json['boundingBox'] as Map<String, dynamic>),
      isDotted: json['isDotted'] as bool,
      hasArrow: json['hasArrow'] as bool,
      id: json['id'] as String,
      showTraversalTime: json['showTraversalTime'] as bool? ?? false,
      traversalSpeedProfile: $enumDecodeNullable(
              _$TraversalSpeedProfileEnumMap, json['traversalSpeedProfile']) ??
          TraversalSpeedProfile.running,
    );

Map<String, dynamic> _$FreeDrawingToJson(FreeDrawing instance) =>
    <String, dynamic>{
      'color': const ColorConverter().toJson(instance.color),
      'isDotted': instance.isDotted,
      'hasArrow': instance.hasArrow,
      'id': instance.id,
      'boundingBox': instance.boundingBox,
      'listOfPoints': const OffsetListConverter().toJson(instance.listOfPoints),
      'showTraversalTime': instance.showTraversalTime,
      'traversalSpeedProfile':
          _$TraversalSpeedProfileEnumMap[instance.traversalSpeedProfile]!,
    };

const _$TraversalSpeedProfileEnumMap = {
  TraversalSpeedProfile.running: 'running',
};

Value? _$JsonConverterFromJson<Json, Value>(
  Object? json,
  Value? Function(Json json) fromJson,
) =>
    json == null ? null : fromJson(json as Json);

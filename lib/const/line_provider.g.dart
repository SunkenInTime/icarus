// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'line_provider.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

LineUp _$LineUpFromJson(Map<String, dynamic> json) => LineUp(
      id: json['id'] as String,
      agent: PlacedAgent.fromJson(json['agent'] as Map<String, dynamic>),
      ability: PlacedAbility.fromJson(json['ability'] as Map<String, dynamic>),
      youtubeLink: json['youtubeLink'] as String,
      images: (json['images'] as List<dynamic>)
          .map((e) => SimpleImageData.fromJson(e as Map<String, dynamic>))
          .toList(),
      notes: json['notes'] as String,
    );

Map<String, dynamic> _$LineUpToJson(LineUp instance) => <String, dynamic>{
      'id': instance.id,
      'agent': instance.agent,
      'ability': instance.ability,
      'youtubeLink': instance.youtubeLink,
      'notes': instance.notes,
      'images': instance.images,
    };

SimpleImageData _$SimpleImageDataFromJson(Map<String, dynamic> json) =>
    SimpleImageData(
      id: json['id'] as String,
      fileExtension: json['fileExtension'] as String,
    );

Map<String, dynamic> _$SimpleImageDataToJson(SimpleImageData instance) =>
    <String, dynamic>{
      'id': instance.id,
      'fileExtension': instance.fileExtension,
    };

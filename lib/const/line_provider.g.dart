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

LineUpItem _$LineUpItemFromJson(Map<String, dynamic> json) => LineUpItem(
      id: json['id'] as String,
      ability: PlacedAbility.fromJson(json['ability'] as Map<String, dynamic>),
      youtubeLink: json['youtubeLink'] as String? ?? '',
      notes: json['notes'] as String? ?? '',
      images: (json['images'] as List<dynamic>?)
              ?.map((e) => SimpleImageData.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );

Map<String, dynamic> _$LineUpItemToJson(LineUpItem instance) =>
    <String, dynamic>{
      'id': instance.id,
      'ability': instance.ability,
      'youtubeLink': instance.youtubeLink,
      'notes': instance.notes,
      'images': instance.images,
    };

LineUpGroup _$LineUpGroupFromJson(Map<String, dynamic> json) => LineUpGroup(
      id: json['id'] as String,
      agent: PlacedAgent.fromJson(json['agent'] as Map<String, dynamic>),
      items: (json['items'] as List<dynamic>)
          .map((e) => LineUpItem.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$LineUpGroupToJson(LineUpGroup instance) =>
    <String, dynamic>{
      'id': instance.id,
      'agent': instance.agent,
      'items': instance.items,
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

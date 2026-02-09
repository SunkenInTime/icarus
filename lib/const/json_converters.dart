import 'dart:convert' as convert;
import 'dart:typed_data' as typed;

import 'package:flutter/material.dart';
import 'package:icarus/const/agents.dart';
import 'package:json_annotation/json_annotation.dart';

class OffsetConverter implements JsonConverter<Offset, Map<String, dynamic>> {
  const OffsetConverter();

  @override
  Offset fromJson(Map<String, dynamic> json) {
    return Offset(json['dx'] as double, json['dy'] as double);
  }

  @override
  Map<String, dynamic> toJson(Offset offset) {
    return {'dx': offset.dx, 'dy': offset.dy};
  }
}

const _agentTypeEnumMap = {
  AgentType.jett: 'jett',
  AgentType.raze: 'raze',
  AgentType.pheonix: 'pheonix',
  AgentType.astra: 'astra',
  AgentType.clove: 'clove',
  AgentType.breach: 'breach',
  AgentType.iso: 'iso',
  AgentType.viper: 'viper',
  AgentType.deadlock: 'deadlock',
  AgentType.yoru: 'yoru',
  AgentType.sova: 'sova',
  AgentType.skye: 'skye',
  AgentType.kayo: 'kayo',
  AgentType.killjoy: 'killjoy',
  AgentType.brimstone: 'brimstone',
  AgentType.cypher: 'cypher',
  AgentType.chamber: 'chamber',
  AgentType.fade: 'fade',
  AgentType.gekko: 'gekko',
  AgentType.harbor: 'harbor',
  AgentType.neon: 'neon',
  AgentType.omen: 'omen',
  AgentType.reyna: 'reyna',
  AgentType.sage: 'sage',
  AgentType.vyse: 'vyse',
  AgentType.tejo: 'tejo',
  AgentType.waylay: 'waylay',
  AgentType.veto: 'veto',
};

class AbilityInfoConverter
    implements JsonConverter<AbilityInfo, Map<String, dynamic>> {
  const AbilityInfoConverter();

  @override
  AbilityInfo fromJson(Map<String, dynamic> json) {
    final agentType = $enumDecode(_agentTypeEnumMap, json["type"]);
    return AgentData.abilityFor(agentType, json["index"] as int);
  }

  @override
  Map<String, dynamic> toJson(AbilityInfo abilityInfo) {
    return {
      'type': _agentTypeEnumMap[abilityInfo.type],
      'index': abilityInfo.index
    };
  }
}

class Uint8ListConverter implements JsonConverter<typed.Uint8List, String> {
  const Uint8ListConverter();

  @override
  typed.Uint8List fromJson(String json) {
    return convert.base64Decode(json);
  }

  @override
  String toJson(typed.Uint8List bytes) {
    return convert.base64Encode(bytes);
  }
}

class ColorConverter implements JsonConverter<Color, String> {
  const ColorConverter();

  @override
  Color fromJson(String json) {
    // Handle null or empty string
    if (json.isEmpty) {
      return Colors.transparent;
    }

    // Remove the hash if it exists
    final hexColor = json.startsWith('#') ? json.substring(1) : json;

    // Parse the hex string to an integer
    final intColor = int.parse(hexColor, radix: 16);

    // If the hex is 6 digits (RRGGBB), add the alpha channel
    if (hexColor.length == 6) {
      return Color.fromARGB(
        255,
        (intColor >> 16) & 0xFF,
        (intColor >> 8) & 0xFF,
        intColor & 0xFF,
      );
    }

    // If the hex is 8 digits (AARRGGBB)
    return Color.fromARGB(
      (intColor >> 24) & 0xFF,
      (intColor >> 16) & 0xFF,
      (intColor >> 8) & 0xFF,
      intColor & 0xFF,
    );
  }

  @override
  String toJson(Color color) {
    // Handle null color
    return _colorToHex(color);
  }

  // Helper method to convert Color to hex string
  String _colorToHex(Color color, {bool leadingHashSign = true}) {
    final hexA = (color.a * 255).round().toRadixString(16).padLeft(2, '0');
    final hexR = (color.r * 255).round().toRadixString(16).padLeft(2, '0');
    final hexG = (color.g * 255).round().toRadixString(16).padLeft(2, '0');
    final hexB = (color.b * 255).round().toRadixString(16).padLeft(2, '0');

    return '${leadingHashSign ? '#' : ''}$hexA$hexR$hexG$hexB';
  }
}

class OffsetListConverter
    implements JsonConverter<List<Offset>, List<dynamic>> {
  const OffsetListConverter();
  final _offsetConverter = const OffsetConverter();

  @override
  List<Offset> fromJson(List<dynamic> json) {
    return json
        .map((pointJson) =>
            _offsetConverter.fromJson(pointJson as Map<String, dynamic>))
        .toList();
  }

  @override
  List<dynamic> toJson(List<Offset> offsets) {
    return offsets.map(_offsetConverter.toJson).toList();
  }
}

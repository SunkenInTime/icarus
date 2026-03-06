import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:icarus/theme/ui_theme_tokens.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class UiThemeProfile {
  UiThemeProfile({
    required this.id,
    required this.name,
    required this.colorValues,
    required this.shadowValues,
    required this.isBuiltIn,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String name;
  final Map<String, int> colorValues;
  final Map<String, List<UiShadowLayerDefinition>> shadowValues;
  final bool isBuiltIn;
  final DateTime createdAt;

  UiThemeProfile copyWith({
    String? id,
    String? name,
    Map<String, int>? colorValues,
    Map<String, List<UiShadowLayerDefinition>>? shadowValues,
    bool? isBuiltIn,
    DateTime? createdAt,
  }) {
    return UiThemeProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      colorValues: colorValues ?? this.colorValues,
      shadowValues: shadowValues ?? this.shadowValues,
      isBuiltIn: isBuiltIn ?? this.isBuiltIn,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'isBuiltIn': isBuiltIn,
      'createdAt': createdAt.toIso8601String(),
      'colors': colorValues,
      'shadows': {
        for (final entry in shadowValues.entries)
          entry.key: entry.value.map((layer) => layer.toJson()).toList(),
      },
    };
  }

  factory UiThemeProfile.fromJson(Map<String, dynamic> json) {
    final colorJson = (json['colors'] as Map?) ?? const {};
    final shadowJson = (json['shadows'] as Map?) ?? const {};

    final colors = <String, int>{
      for (final entry in colorJson.entries)
        entry.key.toString(): (entry.value as num).toInt(),
    };

    final shadows = <String, List<UiShadowLayerDefinition>>{
      for (final entry in shadowJson.entries)
        entry.key.toString(): (entry.value as List)
            .map((item) => UiShadowLayerDefinition.fromJson(
                Map<String, dynamic>.from(item as Map)))
            .toList(),
    };

    return UiThemeProfile(
      id: json['id']?.toString() ?? 'unknown',
      name: json['name']?.toString() ?? 'Untitled',
      isBuiltIn: json['isBuiltIn'] == true,
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.now(),
      colorValues: colors,
      shadowValues: shadows,
    );
  }

  String encode() => jsonEncode(toJson());

  static UiThemeProfile decode(String value) {
    return UiThemeProfile.fromJson(
      Map<String, dynamic>.from(jsonDecode(value) as Map),
    );
  }
}

class UiThemeResolvedData {
  UiThemeResolvedData({
    required this.colors,
    required this.shadows,
  });

  final Map<String, int> colors;
  final Map<String, List<UiShadowLayerDefinition>> shadows;

  Color color(String id) {
    final value = colors[id] ?? UiThemeTokenRegistry.colorById(id).defaultColorValue;
    return Color(value);
  }

  List<UiShadowLayerDefinition> shadowLayers(String id) {
    final layers = shadows[id];
    if (layers == null || layers.isEmpty) {
      return UiThemeTokenRegistry.shadowById(id).defaultLayers;
    }
    return layers;
  }

  List<BoxShadow> boxShadows(String id) {
    return shadowLayers(id).map((layer) => layer.toBoxShadow()).toList();
  }

  List<Shadow> textShadows(String id) {
    return shadowLayers(id).map((layer) => layer.toTextShadow()).toList();
  }

  ShadColorScheme get shadColorScheme {
    return ShadColorScheme(
      background: color(UiThemeTokenIds.shadBackground),
      foreground: color(UiThemeTokenIds.shadForeground),
      card: color(UiThemeTokenIds.shadCard),
      cardForeground: color(UiThemeTokenIds.shadCardForeground),
      popover: color(UiThemeTokenIds.shadPopover),
      popoverForeground: color(UiThemeTokenIds.shadPopoverForeground),
      secondary: color(UiThemeTokenIds.shadSecondary),
      secondaryForeground: color(UiThemeTokenIds.shadSecondaryForeground),
      muted: color(UiThemeTokenIds.shadMuted),
      mutedForeground: color(UiThemeTokenIds.shadMutedForeground),
      accent: color(UiThemeTokenIds.shadAccent),
      accentForeground: color(UiThemeTokenIds.shadAccentForeground),
      border: color(UiThemeTokenIds.shadBorder),
      input: color(UiThemeTokenIds.shadInput),
      primary: color(UiThemeTokenIds.shadPrimary),
      primaryForeground: color(UiThemeTokenIds.shadPrimaryForeground),
      ring: color(UiThemeTokenIds.shadRing),
      selection: color(UiThemeTokenIds.shadSelection),
      destructive: color(UiThemeTokenIds.shadDestructive),
      destructiveForeground: color(UiThemeTokenIds.shadDestructiveForeground),
    );
  }

  Map<String, String> exportColorHexMap() {
    return {
      for (final token in UiThemeTokenRegistry.colorTokens)
        token.id: _toHex(colors[token.id] ?? token.defaultColorValue),
    };
  }

  Map<String, List<Map<String, dynamic>>> exportShadowMap() {
    return {
      for (final token in UiThemeTokenRegistry.shadowTokens)
        token.id: shadowLayers(token.id)
            .map((layer) => {
                  'color': _toHex(layer.colorValue),
                  'blurRadius': layer.blurRadius,
                  'spreadRadius': layer.spreadRadius,
                  'offsetX': layer.offsetX,
                  'offsetY': layer.offsetY,
                })
            .toList(),
    };
  }

  static String _toHex(int colorValue) {
    final alpha = (colorValue >> 24) & 0xFF;
    final rgb = colorValue & 0x00FFFFFF;
    if (alpha == 0xFF) {
      return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
    }
    return '#${colorValue.toRadixString(16).padLeft(8, '0').toUpperCase()}';
  }
}

class UiThemeState {
  const UiThemeState({
    required this.profiles,
    required this.activeProfileId,
  });

  final List<UiThemeProfile> profiles;
  final String activeProfileId;

  UiThemeProfile get activeProfile {
    return profiles.firstWhere(
      (profile) => profile.id == activeProfileId,
      orElse: () => profiles.first,
    );
  }

  UiThemeState copyWith({
    List<UiThemeProfile>? profiles,
    String? activeProfileId,
  }) {
    return UiThemeState(
      profiles: profiles ?? this.profiles,
      activeProfileId: activeProfileId ?? this.activeProfileId,
    );
  }
}


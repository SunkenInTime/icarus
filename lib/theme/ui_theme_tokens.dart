import 'package:flutter/material.dart';

class UiColorTokenDefinition {
  const UiColorTokenDefinition({
    required this.id,
    required this.category,
    required this.defaultColorValue,
    required this.label,
    required this.usageDescription,
    required this.affectedElements,
    this.aliasOf,
  });

  final String id;
  final String category;
  final int defaultColorValue;
  final String label;
  final String usageDescription;
  final List<String> affectedElements;
  final String? aliasOf;
}

class UiShadowLayerDefinition {
  const UiShadowLayerDefinition({
    required this.colorValue,
    required this.blurRadius,
    required this.spreadRadius,
    required this.offsetX,
    required this.offsetY,
  });

  final int colorValue;
  final double blurRadius;
  final double spreadRadius;
  final double offsetX;
  final double offsetY;

  Map<String, dynamic> toJson() {
    return {
      'color': colorValue,
      'blurRadius': blurRadius,
      'spreadRadius': spreadRadius,
      'offsetX': offsetX,
      'offsetY': offsetY,
    };
  }

  factory UiShadowLayerDefinition.fromJson(Map<String, dynamic> json) {
    return UiShadowLayerDefinition(
      colorValue: (json['color'] as num?)?.toInt() ?? 0xFF000000,
      blurRadius: (json['blurRadius'] as num?)?.toDouble() ?? 0,
      spreadRadius: (json['spreadRadius'] as num?)?.toDouble() ?? 0,
      offsetX: (json['offsetX'] as num?)?.toDouble() ?? 0,
      offsetY: (json['offsetY'] as num?)?.toDouble() ?? 0,
    );
  }

  UiShadowLayerDefinition copyWith({
    int? colorValue,
    double? blurRadius,
    double? spreadRadius,
    double? offsetX,
    double? offsetY,
  }) {
    return UiShadowLayerDefinition(
      colorValue: colorValue ?? this.colorValue,
      blurRadius: blurRadius ?? this.blurRadius,
      spreadRadius: spreadRadius ?? this.spreadRadius,
      offsetX: offsetX ?? this.offsetX,
      offsetY: offsetY ?? this.offsetY,
    );
  }

  BoxShadow toBoxShadow() {
    return BoxShadow(
      color: Color(colorValue),
      blurRadius: blurRadius,
      spreadRadius: spreadRadius,
      offset: Offset(offsetX, offsetY),
    );
  }

  Shadow toTextShadow() {
    return Shadow(
      color: Color(colorValue),
      blurRadius: blurRadius,
      offset: Offset(offsetX, offsetY),
    );
  }
}

class UiShadowTokenDefinition {
  const UiShadowTokenDefinition({
    required this.id,
    required this.category,
    required this.label,
    required this.usageDescription,
    required this.affectedElements,
    required this.defaultLayers,
    this.aliasOf,
  });

  final String id;
  final String category;
  final String label;
  final String usageDescription;
  final List<String> affectedElements;
  final List<UiShadowLayerDefinition> defaultLayers;
  final String? aliasOf;
}

class UiThemeTokenIds {
  static const String shadBackground = 'shad.background';
  static const String shadForeground = 'shad.foreground';
  static const String shadCard = 'shad.card';
  static const String shadCardForeground = 'shad.cardForeground';
  static const String shadPopover = 'shad.popover';
  static const String shadPopoverForeground = 'shad.popoverForeground';
  static const String shadSecondary = 'shad.secondary';
  static const String shadSecondaryForeground = 'shad.secondaryForeground';
  static const String shadMuted = 'shad.muted';
  static const String shadMutedForeground = 'shad.mutedForeground';
  static const String shadAccent = 'shad.accent';
  static const String shadAccentForeground = 'shad.accentForeground';
  static const String shadBorder = 'shad.border';
  static const String shadInput = 'shad.input';
  static const String shadPrimary = 'shad.primary';
  static const String shadPrimaryForeground = 'shad.primaryForeground';
  static const String shadRing = 'shad.ring';
  static const String shadSelection = 'shad.selection';
  static const String shadDestructive = 'shad.destructive';
  static const String shadDestructiveForeground = 'shad.destructiveForeground';

  static const String abilityBg = 'app.abilityBg';
  static const String sidebarSurface = 'app.sidebarSurface';
  static const String sidebarHighlight = 'app.sidebarHighlight';
  static const String enemyBg = 'app.enemyBg';
  static const String allyBg = 'app.allyBg';
  static const String enemyOutline = 'app.enemyOutline';
  static const String allyOutline = 'app.allyOutline';
  static const String attackBadge = 'app.attackBadge';
  static const String defendBadge = 'app.defendBadge';
  static const String mixedBadge = 'app.mixedBadge';
  static const String tagNeutral = 'app.tagNeutral';
  static const String tagGreen = 'app.tagGreen';
  static const String tagBlue = 'app.tagBlue';
  static const String tagAmber = 'app.tagAmber';
  static const String tagRed = 'app.tagRed';
  static const String tagPurple = 'app.tagPurple';
  static const String favoriteOn = 'app.favoriteOn';
  static const String favoriteOff = 'app.favoriteOff';
  static const String favoriteRemove = 'app.favoriteRemove';
  static const String scrollbarThumb = 'app.scrollbarThumb';
  static const String mapBackdropCenter = 'app.mapBackdropCenter';
  static const String mapTileOverlay = 'app.mapTileOverlay';
  static const String swatchOutline = 'app.swatchOutline';
  static const String swatchSelected = 'app.swatchSelected';
  static const String textCardBackground = 'app.textCardBackground';
  static const String imageCardBackground = 'app.imageCardBackground';
  static const String backdropOverlay = 'app.backdropOverlay';

  static const String shadowCard = 'shadow.card';
  static const String shadowRaised = 'shadow.raised';
  static const String shadowFavoriteIcon = 'shadow.favoriteIcon';
  static const String shadowTextHandle = 'shadow.textHandle';
  static const String shadowMapTitle = 'shadow.mapTitle';
  static const String shadowFolderGlow = 'shadow.folderGlow';
}

class UiThemeTokenRegistry {
  static const List<UiColorTokenDefinition> colorTokens = [
    UiColorTokenDefinition(
      id: UiThemeTokenIds.shadBackground,
      category: 'Shad Theme',
      defaultColorValue: 0xFF09090B,
      label: 'Background',
      usageDescription: 'Main app background surface color.',
      affectedElements: ['Global app background', 'Sheets', 'Dialogs'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.shadForeground,
      category: 'Shad Theme',
      defaultColorValue: 0xFFFAFAFA,
      label: 'Foreground',
      usageDescription: 'Primary foreground text/icon color.',
      affectedElements: ['Primary text', 'Readable foreground icons'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.shadCard,
      category: 'Shad Theme',
      defaultColorValue: 0xFF18181B,
      label: 'Card',
      usageDescription: 'Card and panel backgrounds.',
      affectedElements: ['Cards', 'Panels', 'Group containers'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.shadCardForeground,
      category: 'Shad Theme',
      defaultColorValue: 0xFFFAFAFA,
      label: 'Card Foreground',
      usageDescription: 'Text/icons shown on card surfaces.',
      affectedElements: ['Card labels', 'Card iconography'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.shadPopover,
      category: 'Shad Theme',
      defaultColorValue: 0xFF18181B,
      label: 'Popover',
      usageDescription: 'Popover/dialog menu surfaces.',
      affectedElements: ['Context menus', 'Dropdown popovers'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.shadPopoverForeground,
      category: 'Shad Theme',
      defaultColorValue: 0xFFFAFAFA,
      label: 'Popover Foreground',
      usageDescription: 'Foreground on popovers.',
      affectedElements: ['Popover text', 'Popover icons'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.shadSecondary,
      category: 'Shad Theme',
      defaultColorValue: 0xFF27272A,
      label: 'Secondary',
      usageDescription: 'Secondary surface color.',
      affectedElements: ['Secondary buttons', 'Secondary containers'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.shadSecondaryForeground,
      category: 'Shad Theme',
      defaultColorValue: 0xFFFAFAFA,
      label: 'Secondary Foreground',
      usageDescription: 'Foreground on secondary surfaces.',
      affectedElements: ['Secondary labels'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.shadMuted,
      category: 'Shad Theme',
      defaultColorValue: 0xFF27272A,
      label: 'Muted',
      usageDescription: 'Muted background color.',
      affectedElements: ['Muted backgrounds', 'Low-emphasis states'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.shadMutedForeground,
      category: 'Shad Theme',
      defaultColorValue: 0xFFA1A1AA,
      label: 'Muted Foreground',
      usageDescription: 'Muted text/icon color.',
      affectedElements: ['Secondary labels', 'Hints'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.shadAccent,
      category: 'Shad Theme',
      defaultColorValue: 0xFF27272A,
      label: 'Accent',
      usageDescription: 'Accent surface color.',
      affectedElements: ['Accent backgrounds'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.shadAccentForeground,
      category: 'Shad Theme',
      defaultColorValue: 0xFFFAFAFA,
      label: 'Accent Foreground',
      usageDescription: 'Text/icon color for accent surfaces.',
      affectedElements: ['Accent text'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.shadBorder,
      category: 'Shad Theme',
      defaultColorValue: 0xFF27272A,
      label: 'Border',
      usageDescription: 'Standard border color.',
      affectedElements: ['Card borders', 'Input borders'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.shadInput,
      category: 'Shad Theme',
      defaultColorValue: 0xFF27272A,
      label: 'Input',
      usageDescription: 'Input background/border base.',
      affectedElements: ['Inputs', 'Editable fields'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.shadPrimary,
      category: 'Shad Theme',
      defaultColorValue: 0xFF7C3AED,
      label: 'Primary',
      usageDescription: 'Primary interactive color.',
      affectedElements: ['Primary buttons', 'Active highlights'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.shadPrimaryForeground,
      category: 'Shad Theme',
      defaultColorValue: 0xFFF9FAFB,
      label: 'Primary Foreground',
      usageDescription: 'Foreground on primary elements.',
      affectedElements: ['Primary button labels'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.shadRing,
      category: 'Shad Theme',
      defaultColorValue: 0xFF7C3AED,
      label: 'Ring',
      usageDescription: 'Focus ring and selection ring color.',
      affectedElements: ['Focus rings', 'Selection outlines'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.shadSelection,
      category: 'Shad Theme',
      defaultColorValue: 0xFF4C1D95,
      label: 'Selection',
      usageDescription: 'Selection overlay color.',
      affectedElements: ['Selection fills'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.shadDestructive,
      category: 'Shad Theme',
      defaultColorValue: 0xFFEF4444,
      label: 'Destructive',
      usageDescription: 'Destructive action color.',
      affectedElements: ['Delete buttons', 'Error accents'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.shadDestructiveForeground,
      category: 'Shad Theme',
      defaultColorValue: 0xFFFAFAFA,
      label: 'Destructive Foreground',
      usageDescription: 'Foreground on destructive elements.',
      affectedElements: ['Delete labels/icons'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.abilityBg,
      category: 'Gameplay',
      defaultColorValue: 0xFF1B1B1B,
      label: 'Ability Background',
      usageDescription: 'Ability tile backing color.',
      affectedElements: ['Ability icons on map'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.sidebarSurface,
      category: 'App Surfaces',
      defaultColorValue: 0xFF141114,
      label: 'Sidebar Surface',
      usageDescription: 'Sidebar and shell dark surface.',
      affectedElements: ['Sidebar panel', 'Legacy menu surfaces'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.sidebarHighlight,
      category: 'App Surfaces',
      defaultColorValue: 0xFF27272A,
      label: 'Sidebar Highlight',
      usageDescription: 'Sidebar hover/highlight border.',
      affectedElements: ['Sidebar controls', 'Legacy borders'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.enemyBg,
      category: 'Gameplay',
      defaultColorValue: 0xFF772727,
      label: 'Enemy Agent Fill',
      usageDescription: 'Enemy agent background fill.',
      affectedElements: ['Enemy agent chips', 'Enemy feedback widgets'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.allyBg,
      category: 'Gameplay',
      defaultColorValue: 0xFF3A7E5D,
      label: 'Ally Agent Fill',
      usageDescription: 'Ally agent background fill.',
      affectedElements: ['Ally agent chips', 'Ally feedback widgets'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.enemyOutline,
      category: 'Gameplay',
      defaultColorValue: 0x8BFF5252,
      label: 'Enemy Agent Outline',
      usageDescription: 'Enemy agent outline stroke.',
      affectedElements: ['Enemy agent outlines'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.allyOutline,
      category: 'Gameplay',
      defaultColorValue: 0x6A69F0AF,
      label: 'Ally Agent Outline',
      usageDescription: 'Ally agent outline stroke.',
      affectedElements: ['Ally agent outlines'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.attackBadge,
      category: 'Status',
      defaultColorValue: 0xFFFF5252,
      label: 'Attack Badge',
      usageDescription: 'Attack state color.',
      affectedElements: ['Attack labels'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.defendBadge,
      category: 'Status',
      defaultColorValue: 0xFF40C4FF,
      label: 'Defend Badge',
      usageDescription: 'Defend state color.',
      affectedElements: ['Defend labels'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.mixedBadge,
      category: 'Status',
      defaultColorValue: 0xFFFFAB40,
      label: 'Mixed Badge',
      usageDescription: 'Mixed state color.',
      affectedElements: ['Mixed labels'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.tagNeutral,
      category: 'Tag Palette',
      defaultColorValue: 0xFFC5C5C5,
      label: 'Tag Neutral',
      usageDescription: 'Neutral tag strip color.',
      affectedElements: ['Image tags', 'Text tags'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.tagGreen,
      category: 'Tag Palette',
      defaultColorValue: 0xFF22C55E,
      label: 'Tag Green',
      usageDescription: 'Tag palette green option.',
      affectedElements: ['Tag picker'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.tagBlue,
      category: 'Tag Palette',
      defaultColorValue: 0xFF3B82F6,
      label: 'Tag Blue',
      usageDescription: 'Tag palette blue option.',
      affectedElements: ['Tag picker'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.tagAmber,
      category: 'Tag Palette',
      defaultColorValue: 0xFFF59E0B,
      label: 'Tag Amber',
      usageDescription: 'Tag palette amber option.',
      affectedElements: ['Tag picker'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.tagRed,
      category: 'Tag Palette',
      defaultColorValue: 0xFFEF4444,
      label: 'Tag Red',
      usageDescription: 'Tag palette red option.',
      affectedElements: ['Tag picker'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.tagPurple,
      category: 'Tag Palette',
      defaultColorValue: 0xFFA855F7,
      label: 'Tag Purple',
      usageDescription: 'Tag palette purple option.',
      affectedElements: ['Tag picker'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.favoriteOn,
      category: 'Status',
      defaultColorValue: 0xFFFF9800,
      label: 'Favorite On',
      usageDescription: 'Favorite/star active color.',
      affectedElements: ['Favorite stars'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.favoriteOff,
      category: 'Status',
      defaultColorValue: 0xFF9AA0A6,
      label: 'Favorite Off',
      usageDescription: 'Favorite/star idle color.',
      affectedElements: ['Favorite stars'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.favoriteRemove,
      category: 'Status',
      defaultColorValue: 0xFFE53935,
      label: 'Favorite Remove',
      usageDescription: 'Favorite remove intent color.',
      affectedElements: ['Favorite remove icon'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.scrollbarThumb,
      category: 'App Surfaces',
      defaultColorValue: 0xFF353435,
      label: 'Scrollbar Thumb',
      usageDescription: 'Custom scrollbar thumb.',
      affectedElements: ['Sidebar scrollbar'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.mapBackdropCenter,
      category: 'Map Canvas',
      defaultColorValue: 0xFF18181B,
      label: 'Map Backdrop Center',
      usageDescription: 'Center color for map radial backdrop.',
      affectedElements: ['Interactive map background', 'Screenshot background'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.mapTileOverlay,
      category: 'Map Canvas',
      defaultColorValue: 0x26FFFFFF,
      label: 'Map Tile Hover Overlay',
      usageDescription: 'Overlay tint for hovered map tile.',
      affectedElements: ['Map selector tiles'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.swatchOutline,
      category: 'Controls',
      defaultColorValue: 0xFF272727,
      label: 'Swatch Outline',
      usageDescription: 'Color swatch interior outline.',
      affectedElements: ['Color swatches', 'Tag pickers'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.swatchSelected,
      category: 'Controls',
      defaultColorValue: 0xFF7C4DFF,
      label: 'Swatch Selected Ring',
      usageDescription: 'Selection ring around chosen swatches.',
      affectedElements: ['Color swatches'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.textCardBackground,
      category: 'Canvas Elements',
      defaultColorValue: 0xFF000000,
      label: 'Text Card Background',
      usageDescription: 'Background of draggable text card.',
      affectedElements: ['Text widget card'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.imageCardBackground,
      category: 'Canvas Elements',
      defaultColorValue: 0xFF141414,
      label: 'Image Card Background',
      usageDescription: 'Inner background behind image thumbnails.',
      affectedElements: ['Image widget card'],
    ),
    UiColorTokenDefinition(
      id: UiThemeTokenIds.backdropOverlay,
      category: 'Overlays',
      defaultColorValue: 0x8A000000,
      label: 'Backdrop Overlay',
      usageDescription: 'Global dark overlay for fullscreen previews.',
      affectedElements: ['Image fullscreen', 'Lineup carousel'],
    ),
  ];

  static const List<UiShadowTokenDefinition> shadowTokens = [
    UiShadowTokenDefinition(
      id: UiThemeTokenIds.shadowCard,
      category: 'Shadows',
      label: 'Card Foreground Shadow',
      usageDescription: 'Primary card shadow used across UI cards.',
      affectedElements: ['Strategy cards', 'Panels', 'Dialogs'],
      defaultLayers: [
        UiShadowLayerDefinition(
          colorValue: 0x8A000000,
          blurRadius: 12,
          spreadRadius: 0,
          offsetX: 0,
          offsetY: 4,
        ),
      ],
    ),
    UiShadowTokenDefinition(
      id: UiThemeTokenIds.shadowRaised,
      category: 'Shadows',
      label: 'Raised Control Shadow',
      usageDescription: 'Subtle raised shadow for active controls.',
      affectedElements: ['Segmented control indicator', 'Page rows'],
      defaultLayers: [
        UiShadowLayerDefinition(
          colorValue: 0x64000000,
          blurRadius: 4,
          spreadRadius: 0,
          offsetX: 0,
          offsetY: 2,
        ),
      ],
    ),
    UiShadowTokenDefinition(
      id: UiThemeTokenIds.shadowFavoriteIcon,
      category: 'Shadows',
      label: 'Favorite Icon Shadow',
      usageDescription: 'Shadow behind favorite icon in agent grid.',
      affectedElements: ['Favorite star icon'],
      defaultLayers: [
        UiShadowLayerDefinition(
          colorValue: 0x64000000,
          blurRadius: 4,
          spreadRadius: 0,
          offsetX: 0,
          offsetY: 2,
        ),
      ],
    ),
    UiShadowTokenDefinition(
      id: UiThemeTokenIds.shadowTextHandle,
      category: 'Shadows',
      label: 'Text Resize Handle Shadow',
      usageDescription: 'Shadow used by text resize handle.',
      affectedElements: ['Text resize affordance'],
      defaultLayers: [
        UiShadowLayerDefinition(
          colorValue: 0x1F000000,
          blurRadius: 2,
          spreadRadius: 0,
          offsetX: 0,
          offsetY: 1,
        ),
      ],
    ),
    UiShadowTokenDefinition(
      id: UiThemeTokenIds.shadowMapTitle,
      category: 'Shadows',
      label: 'Map Title Shadow',
      usageDescription: 'Shadow for map tile title text.',
      affectedElements: ['Map selector title text'],
      defaultLayers: [
        UiShadowLayerDefinition(
          colorValue: 0xFF000000,
          blurRadius: 2,
          spreadRadius: 0,
          offsetX: 0,
          offsetY: 2,
        ),
      ],
    ),
    UiShadowTokenDefinition(
      id: UiThemeTokenIds.shadowFolderGlow,
      category: 'Shadows',
      label: 'Folder Glow Shadow',
      usageDescription: 'Glow layer under folder pills.',
      affectedElements: ['Folder pills'],
      defaultLayers: [
        UiShadowLayerDefinition(
          colorValue: 0x4DFFFFFF,
          blurRadius: 8,
          spreadRadius: 0,
          offsetX: 0,
          offsetY: 2,
        ),
      ],
    ),
  ];

  static UiColorTokenDefinition colorById(String id) {
    return colorTokens.firstWhere((token) => token.id == id);
  }

  static UiShadowTokenDefinition shadowById(String id) {
    return shadowTokens.firstWhere((token) => token.id == id);
  }

  static Map<String, int> defaultColorMap() {
    final map = <String, int>{
      for (final token in colorTokens) token.id: token.defaultColorValue,
    };
    for (final token in colorTokens) {
      if (token.aliasOf != null && map.containsKey(token.aliasOf)) {
        map[token.id] = map[token.aliasOf!]!;
      }
    }
    return map;
  }

  static Map<String, List<UiShadowLayerDefinition>> defaultShadowMap() {
    final map = <String, List<UiShadowLayerDefinition>>{
      for (final token in shadowTokens)
        token.id: List<UiShadowLayerDefinition>.from(token.defaultLayers),
    };
    for (final token in shadowTokens) {
      if (token.aliasOf != null && map.containsKey(token.aliasOf)) {
        map[token.id] = List<UiShadowLayerDefinition>.from(map[token.aliasOf!]!);
      }
    }
    return map;
  }
}


import 'package:flutter/material.dart';
import 'package:icarus/const/custom_icons.dart';

const int folderIconRegistryVersion = 92;

enum FolderIconRenderKind {
  material,
  asset,
}

enum FolderIconCategory {
  symbol,
  role,
}

class FolderIconDefinition {
  const FolderIconDefinition.material({
    required this.id,
    required IconData icon,
    this.label = '',
    this.category = FolderIconCategory.symbol,
    this.hiddenFromPicker = false,
  })  : kind = FolderIconRenderKind.material,
        iconData = icon,
        assetPath = '';

  const FolderIconDefinition.asset({
    required this.id,
    required this.assetPath,
    this.label = '',
    this.category = FolderIconCategory.role,
    this.hiddenFromPicker = false,
  })  : kind = FolderIconRenderKind.asset,
        iconData = null;

  final int id;
  final FolderIconRenderKind kind;
  final IconData? iconData;
  final String assetPath;
  final String label;
  final FolderIconCategory category;
  final bool hiddenFromPicker;

  String get stableSignature {
    final icon = iconData;
    if (icon != null) {
      return [
        'material',
        icon.codePoint,
        icon.fontFamily ?? '',
        icon.fontPackage ?? '',
        icon.matchTextDirection,
        icon.fontFamilyFallback?.join(',') ?? '',
      ].join('|');
    }
    return 'asset|$assetPath';
  }
}

class FolderIconRegistry {
  FolderIconRegistry._();

  static const int legacyFolderId = 0;
  static const int defaultId = 1;
  static const int controllerRoleId = 1000;
  static const int duelistRoleId = 1001;
  static const int initiatorRoleId = 1002;
  static const int sentinelRoleId = 1003;

  static const List<FolderIconDefinition> _baseEntries = [
    FolderIconDefinition.material(
      id: legacyFolderId,
      icon: Icons.folder,
      hiddenFromPicker: true,
    ),
    FolderIconDefinition.material(id: 1, icon: Icons.star_rate_rounded),
    FolderIconDefinition.material(id: 2, icon: Icons.ac_unit_sharp),
    FolderIconDefinition.material(id: 3, icon: Icons.bug_report),
    FolderIconDefinition.material(id: 4, icon: Icons.cake),
    FolderIconDefinition.material(id: 5, icon: Icons.code),
    FolderIconDefinition.material(id: 6, icon: Icons.add_shopping_cart_rounded),
    FolderIconDefinition.material(id: 7, icon: Icons.airline_stops_sharp),
    FolderIconDefinition.material(id: 8, icon: Icons.all_inclusive),
    FolderIconDefinition.material(id: 9, icon: Icons.api_rounded),
    FolderIconDefinition.material(id: 10, icon: Icons.drive_folder_upload),
    FolderIconDefinition.material(id: 11, icon: Icons.folder_shared),
    FolderIconDefinition.material(id: 12, icon: Icons.folder_special),
    FolderIconDefinition.material(id: 13, icon: Icons.workspaces),
    FolderIconDefinition.material(id: 14, icon: Icons.category),
    FolderIconDefinition.material(id: 15, icon: Icons.collections_bookmark),
    FolderIconDefinition.material(id: 16, icon: Icons.library_books),
    FolderIconDefinition.material(id: 17, icon: Icons.archive),
    FolderIconDefinition.material(id: 18, icon: Icons.assignment),
    FolderIconDefinition.material(id: 19, icon: Icons.assignment_turned_in),
    FolderIconDefinition.material(id: 20, icon: Icons.dashboard),
    FolderIconDefinition.material(id: 21, icon: Icons.anchor),
    FolderIconDefinition.material(
        id: 22, icon: Icons.hourglass_bottom_outlined),
    FolderIconDefinition.material(id: 23, icon: Icons.image_search),
    FolderIconDefinition.material(id: 24, icon: Icons.view_quilt),
    FolderIconDefinition.material(id: 25, icon: Icons.map),
    FolderIconDefinition.material(id: 26, icon: Icons.place),
    FolderIconDefinition.material(id: 27, icon: Icons.explore),
    FolderIconDefinition.material(id: 28, icon: Icons.explore_off),
    FolderIconDefinition.material(id: 29, icon: Icons.flag),
    FolderIconDefinition.material(id: 30, icon: Icons.outlined_flag),
    FolderIconDefinition.material(id: 31, icon: Icons.emoji_objects),
    FolderIconDefinition.material(id: 32, icon: Icons.lightbulb),
    FolderIconDefinition.material(id: 33, icon: Icons.track_changes),
    FolderIconDefinition.material(id: 34, icon: Icons.timeline),
    FolderIconDefinition.material(id: 35, icon: Icons.sports_esports),
    FolderIconDefinition.material(id: 36, icon: CustomIcons.sword),
    FolderIconDefinition.material(id: 37, icon: Icons.military_tech),
    FolderIconDefinition.material(id: 38, icon: Icons.shield),
    FolderIconDefinition.material(id: 39, icon: Icons.security),
    FolderIconDefinition.material(id: 40, icon: Icons.bolt),
    FolderIconDefinition.material(id: 41, icon: Icons.psychology),
    FolderIconDefinition.asset(
      id: controllerRoleId,
      assetPath: 'assets/agents/controller.webp',
      label: 'Controller',
    ),
    FolderIconDefinition.asset(
      id: duelistRoleId,
      assetPath: 'assets/agents/duelist.webp',
      label: 'Duelist',
    ),
    FolderIconDefinition.asset(
      id: initiatorRoleId,
      assetPath: 'assets/agents/initiator.webp',
      label: 'Initiator',
    ),
    FolderIconDefinition.asset(
      id: sentinelRoleId,
      assetPath: 'assets/agents/sentinel.webp',
      label: 'Sentinel',
    ),
  ];

  static final List<FolderIconDefinition> entries = [
    ..._baseEntries,
  ];

  static final Map<int, FolderIconDefinition> _byId = {
    for (final entry in entries) entry.id: entry,
  };

  static final List<FolderIconDefinition> pickerEntries = [
    for (final entry in entries)
      if (!entry.hiddenFromPicker) entry,
  ];

  static List<FolderIconDefinition> pickerEntriesFor(
    FolderIconCategory? category,
  ) {
    return [
      for (final entry in pickerEntries)
        if (category == null || entry.category == category) entry,
    ];
  }

  static FolderIconDefinition resolve(int id) {
    return _byId[id] ?? _byId[defaultId]!;
  }

  static bool isKnownId(int id) => _byId.containsKey(id);

  static int idForStoredValue(Object? value) {
    return switch (value) {
      final int id => id,
      final IconData icon => idForLegacyIconData(icon),
      _ => defaultId,
    };
  }

  static int idForLegacyIconData(IconData icon) {
    return tryIdForLegacyIconData(icon) ?? defaultId;
  }

  static int? tryIdForLegacyIconData(IconData icon) {
    for (final entry in entries) {
      final candidate = entry.iconData;
      if (candidate != null && _sameIconData(candidate, icon)) {
        return entry.id;
      }
    }
    return null;
  }

  static IconData legacyIconDataForId(int id) {
    return _byId[id]?.iconData ?? _byId[defaultId]!.iconData!;
  }

  static bool _sameIconData(IconData a, IconData b) {
    return a.codePoint == b.codePoint &&
        a.fontFamily == b.fontFamily &&
        a.fontPackage == b.fontPackage &&
        a.matchTextDirection == b.matchTextDirection &&
        _sameFontFamilyFallback(a.fontFamilyFallback, b.fontFamilyFallback);
  }

  static bool _sameFontFamilyFallback(List<String>? a, List<String>? b) {
    if (a == null || a.isEmpty) {
      return b == null || b.isEmpty;
    }
    if (b == null || b.length != a.length) {
      return false;
    }
    for (var index = 0; index < a.length; index += 1) {
      if (a[index] != b[index]) {
        return false;
      }
    }
    return true;
  }
}

class FolderIconView extends StatelessWidget {
  const FolderIconView({
    super.key,
    required this.iconId,
    required this.size,
    required this.color,
  });

  final int iconId;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final definition = FolderIconRegistry.resolve(iconId);
    final icon = definition.iconData;
    if (icon != null) {
      return Icon(
        icon,
        color: color,
        size: size,
      );
    }

    return SizedBox.square(
      dimension: size,
      child: Image.asset(
        definition.assetPath,
        fit: BoxFit.contain,
        color: color,
        colorBlendMode: BlendMode.srcIn,
      ),
    );
  }
}

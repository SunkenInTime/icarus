import 'package:hive_ce/hive.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/map_theme_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

class StrategyData extends HiveObject {
  final String id;
  String name;
  final int versionNumber;

  @Deprecated('Use pages instead')
  final List<DrawingElement> drawingData;

  @Deprecated('Use pages instead')
  final List<PlacedAgent> agentData;

  @Deprecated('Use pages instead')
  final List<PlacedAbility> abilityData;

  @Deprecated('Use pages instead')
  final List<PlacedText> textData;

  @Deprecated('Use pages instead')
  final List<PlacedImage> imageData;

  @Deprecated('Use pages instead')
  final List<PlacedUtility> utilityData;

  @Deprecated('Use pages instead')
  final bool isAttack;

  @Deprecated('Use pages instead')
  final StrategySettings strategySettings;

  final List<StrategyPage> pages;
  final MapValue mapData;
  final DateTime lastEdited;
  final DateTime createdAt;

  String? folderID;
  final String? themeProfileId;
  final MapThemePalette? themeOverridePalette;

  StrategyData({
    @Deprecated('Use pages instead') this.isAttack = true,
    @Deprecated('Use pages instead') this.drawingData = const [],
    @Deprecated('Use pages instead') this.agentData = const [],
    @Deprecated('Use pages instead') this.abilityData = const [],
    @Deprecated('Use pages instead') this.textData = const [],
    @Deprecated('Use pages instead') this.imageData = const [],
    @Deprecated('Use pages instead') this.utilityData = const [],
    required this.id,
    required this.name,
    required this.mapData,
    required this.versionNumber,
    required this.lastEdited,
    required this.folderID,
    this.themeProfileId,
    this.themeOverridePalette,
    this.pages = const [],
    DateTime? createdAt,
    @Deprecated('Use pages instead') StrategySettings? strategySettings,
    // ignore: deprecated_member_use_from_same_package
  })  : strategySettings = strategySettings ?? StrategySettings(),
        createdAt = createdAt ?? lastEdited;

  StrategyData copyWith({
    String? id,
    String? name,
    int? versionNumber,
    List<DrawingElement>? drawingData,
    List<PlacedAgent>? agentData,
    List<PlacedAbility>? abilityData,
    List<PlacedText>? textData,
    List<PlacedImage>? imageData,
    List<PlacedUtility>? utilityData,
    List<StrategyPage>? pages,
    MapValue? mapData,
    DateTime? lastEdited,
    bool? isAttack,
    StrategySettings? strategySettings,
    String? folderID,
    DateTime? createdAt,
    String? themeProfileId,
    bool clearThemeProfileId = false,
    MapThemePalette? themeOverridePalette,
    bool clearThemeOverridePalette = false,
  }) {
    return StrategyData(
      id: id ?? this.id,
      name: name ?? this.name,
      versionNumber: versionNumber ?? this.versionNumber,
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      drawingData: drawingData ?? this.drawingData,
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      agentData: agentData ?? this.agentData,
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      abilityData: abilityData ?? this.abilityData,
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      textData: textData ?? this.textData,
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      imageData: imageData ?? this.imageData,
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      utilityData: utilityData ?? this.utilityData,
      pages: pages ?? this.pages,
      mapData: mapData ?? this.mapData,
      lastEdited: lastEdited ?? this.lastEdited,
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      isAttack: isAttack ?? this.isAttack,
      // ignore: deprecated_member_use_from_same_package
      strategySettings: strategySettings ?? this.strategySettings,
      createdAt: createdAt ?? this.createdAt,
      folderID: folderID ?? this.folderID,
      themeProfileId:
          clearThemeProfileId ? null : (themeProfileId ?? this.themeProfileId),
      themeOverridePalette: clearThemeOverridePalette
          ? null
          : (themeOverridePalette ?? this.themeOverridePalette),
    );
  }
}

class StrategyState {
  const StrategyState({
    String? strategyId,
    String? strategyName,
    StrategySource? source,
    this.storageDirectory,
    this.isOpen = false,
    @Deprecated('Use strategyId') String? id,
    @Deprecated('Use strategyName') String? stratName,
    @Deprecated('Use source') bool? isCloudBacked,
    @Deprecated('Use strategySaveStateProvider') bool? isSaved,
    @Deprecated('Use strategySaveStateProvider') bool? hasPendingCloudSync,
    @Deprecated('Use strategySaveStateProvider') String? cloudSyncError,
    @Deprecated('Use strategyPageSessionProvider') String? activePageId,
  })  : strategyId = strategyId ?? id,
        strategyName = strategyName ?? stratName,
        source = source ??
            (isCloudBacked == null
                ? null
                : (isCloudBacked ? StrategySource.cloud : StrategySource.local));

  final String? strategyId;
  final String? strategyName;
  final StrategySource? source;
  final String? storageDirectory;
  final bool isOpen;

  String get id => strategyId ?? 'testID';
  String? get stratName => strategyName;
  bool get isCloudBacked => source == StrategySource.cloud;

  StrategyState copyWith({
    String? strategyId,
    String? strategyName,
    StrategySource? source,
    String? storageDirectory,
    bool? isOpen,
    bool clearStrategyId = false,
    bool clearStrategyName = false,
    bool clearSource = false,
    @Deprecated('Use strategyId') String? id,
    @Deprecated('Use strategyName') String? stratName,
    @Deprecated('Use source') bool? isCloudBacked,
    @Deprecated('Ignored') bool? isSaved,
    @Deprecated('Ignored') bool? hasPendingCloudSync,
    @Deprecated('Ignored') String? cloudSyncError,
    @Deprecated('Ignored') bool clearCloudSyncError = false,
    @Deprecated('Ignored') String? activePageId,
    @Deprecated('Ignored') bool clearActivePageId = false,
  }) {
    final resolvedSource = source ??
        (isCloudBacked == null
            ? this.source
            : (isCloudBacked ? StrategySource.cloud : StrategySource.local));
    return StrategyState(
      strategyId: clearStrategyId ? null : (strategyId ?? id ?? this.strategyId),
      strategyName: clearStrategyName
          ? null
          : (strategyName ?? stratName ?? this.strategyName),
      source: clearSource ? null : resolvedSource,
      storageDirectory: storageDirectory ?? this.storageDirectory,
      isOpen: isOpen ?? this.isOpen,
    );
  }
}

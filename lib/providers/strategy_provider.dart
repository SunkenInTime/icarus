import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, listEquals, visibleForTesting;
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/transition_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/migrations/ability_scale_migration.dart';
import 'package:icarus/migrations/custom_circle_wrapper_migration.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/auto_save_notifier.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/favorite_agents_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/map_theme_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/bounding_box.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/services/archive_manifest.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

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
  StrategyState({
    required this.isSaved,
    required this.stratName,
    required this.id,
    required this.storageDirectory,
    this.activePageId,
  });

  final bool isSaved;
  final String? stratName;
  final String id;
  final String? storageDirectory;
  final String? activePageId;

  StrategyState copyWith({
    bool? isSaved,
    String? stratName,
    String? id,
    String? storageDirectory,
    String? activePageId,
    bool clearActivePageId = false,
  }) {
    return StrategyState(
      isSaved: isSaved ?? this.isSaved,
      stratName: stratName ?? this.stratName,
      id: id ?? this.id,
      storageDirectory: storageDirectory ?? this.storageDirectory,
      activePageId:
          clearActivePageId ? null : (activePageId ?? this.activePageId),
    );
  }
}

final strategyProvider =
    NotifierProvider<StrategyProvider, StrategyState>(StrategyProvider.new);

class NewerVersionImportException implements Exception {
  const NewerVersionImportException({
    required this.importedVersion,
    required this.currentVersion,
  });

  final int importedVersion;
  final int currentVersion;

  static const String userMessage =
      'This strategy was created in a newer version of Icarus. '
      'Please update the app and try again.';

  @override
  String toString() {
    return 'NewerVersionImportException('
        'importedVersion: $importedVersion, '
        'currentVersion: $currentVersion'
        ')';
  }
}

enum ImportIssueCode {
  newerVersion,
  invalidStrategy,
  invalidArchiveMetadata,
  unsupportedFile,
  ioError,
}

class ImportIssue {
  const ImportIssue({
    required this.path,
    required this.code,
  });

  final String path;
  final ImportIssueCode code;
}

class ImportBatchResult {
  const ImportBatchResult({
    required this.strategiesImported,
    required this.foldersCreated,
    this.themeProfilesImported = 0,
    this.globalStateRestored = false,
    required this.issues,
  });

  const ImportBatchResult.empty()
      : strategiesImported = 0,
        foldersCreated = 0,
        themeProfilesImported = 0,
        globalStateRestored = false,
        issues = const [];

  final int strategiesImported;
  final int foldersCreated;
  final int themeProfilesImported;
  final bool globalStateRestored;
  final List<ImportIssue> issues;

  bool get hasImports =>
      strategiesImported > 0 ||
      foldersCreated > 0 ||
      themeProfilesImported > 0 ||
      globalStateRestored;

  ImportBatchResult merge(ImportBatchResult other) {
    return ImportBatchResult(
      strategiesImported: strategiesImported + other.strategiesImported,
      foldersCreated: foldersCreated + other.foldersCreated,
      themeProfilesImported:
          themeProfilesImported + other.themeProfilesImported,
      globalStateRestored: globalStateRestored || other.globalStateRestored,
      issues: [...issues, ...other.issues],
    );
  }
}

class _ImportEntityListing {
  const _ImportEntityListing({
    required this.entities,
    required this.issues,
  });

  final List<FileSystemEntity> entities;
  final List<ImportIssue> issues;
}

class _ArchiveExportState {
  _ArchiveExportState({
    required this.rootDirectory,
  });

  final Directory rootDirectory;
  final List<ArchiveFolderEntry> folders = [];
  final List<ArchiveStrategyEntry> strategies = [];
}

class _ManifestImportData {
  const _ManifestImportData({
    required this.rootDirectory,
    required this.manifestFile,
    required this.manifest,
  });

  final Directory rootDirectory;
  final File manifestFile;
  final ArchiveManifest manifest;
}

class _GlobalImportResult {
  const _GlobalImportResult({
    required this.themeProfilesImported,
    required this.globalStateRestored,
    required this.profileIdRemap,
  });

  final int themeProfilesImported;
  final bool globalStateRestored;
  final Map<String, String> profileIdRemap;
}

class _ZipManifestData {
  const _ZipManifestData({
    required this.manifest,
    required this.rootPrefix,
    required this.filesByPath,
    required this.manifestArchivePath,
  });

  final ArchiveManifest manifest;
  final String rootPrefix;
  final Map<String, ArchiveFile> filesByPath;
  final String manifestArchivePath;
}

class StrategyProvider extends Notifier<StrategyState> {
  String? activePageID;

  @override
  StrategyState build() {
    return StrategyState(
      isSaved: false,
      stratName: null,
      id: "testID",
      storageDirectory: null,
      activePageId: null,
    );
  }

  Timer? _saveTimer;

  bool _saveInProgress = false;
  bool _pendingSave = false;

  void _reportImportFailure(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    required String source,
  }) {
    AppErrorReporter.reportError(
      message,
      error: error,
      stackTrace: stackTrace,
      source: source,
      promptUser: false,
    );
  }

  //Used For Images
  void setFromState(StrategyState newState) {
    state = newState;
  }

  void setUnsaved() async {
    state = state.copyWith(isSaved: false);
    _saveTimer?.cancel();
    _saveTimer = Timer(Settings.autoSaveOffset, () async {
      //Find some way to tell the user that it is saving now()
      if (state.stratName == null) return;
      // ref.read(autoSaveProvider.notifier).ping();
      await _performSave(state.id);
    });
  }

  // For manual “Save now” actions
  Future<void> forceSaveNow(String id) async {
    _saveTimer?.cancel();
    await _performSave(id);
  }

  // Ensures only one save runs at a time; coalesces a pending one
  Future<void> _performSave(String id) async {
    if (_saveInProgress) {
      _pendingSave = true;
      return;
    }

    _saveInProgress = true;
    try {
      ref.read(autoSaveProvider.notifier).ping(); // UI: “Saving…”
      await saveToHive(id);
    } finally {
      _saveInProgress = false;
      if (_pendingSave) {
        _pendingSave = false;
        // Small debounce to coalesce rapid edits during the previous save
        _saveTimer?.cancel();
        // _saveTimer = Timer(const Duration(milliseconds: 500), () {
        //   _performSave(id);
        // });
      }
    }
  }

  Future<Directory> setStorageDirectory(String strategyID) async {
    // final strategyID = state.id;
    // Get the system's application support directory.
    final directory = await getApplicationSupportDirectory();

    // Create a custom directory inside the application support directory.

    final customDirectory = Directory(path.join(directory.path, strategyID));

    if (!await customDirectory.exists()) {
      await customDirectory.create(recursive: true);
    }

    return customDirectory;
  }

  Future<void> clearCurrentStrategy() async {
    activePageID = null;
    ref.read(strategyThemeProvider.notifier).fromStrategy();
    state = StrategyState(
      isSaved: true,
      stratName: null,
      id: "testID",
      storageDirectory: state.storageDirectory,
      activePageId: null,
    );
  }
  // --- MIGRATION: create a first page from legacy flat fields ----------------

  static Future<void> migrateAllStrategies() async {
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    for (final strat in box.values) {
      final legacyMigrated = await migrateLegacyData(strat);
      final worldMigrated = migrateToWorld16x9(legacyMigrated);
      final abilityScaleMigrated = migrateAbilityScale(worldMigrated);
      final squareAoeMigrated = migrateSquareAoeCenter(abilityScaleMigrated);
      final customCircleMigrated =
          migrateCustomCircleWrapper(squareAoeMigrated);
      if (customCircleMigrated != squareAoeMigrated) {
        await box.put(customCircleMigrated.id, customCircleMigrated);
      } else if (squareAoeMigrated != abilityScaleMigrated) {
        await box.put(squareAoeMigrated.id, squareAoeMigrated);
      } else if (abilityScaleMigrated != worldMigrated) {
        await box.put(abilityScaleMigrated.id, abilityScaleMigrated);
      } else if (worldMigrated != legacyMigrated) {
        await box.put(worldMigrated.id, worldMigrated);
      } else if (legacyMigrated != strat) {
        await box.put(legacyMigrated.id, legacyMigrated);
      }
    }
  }

  static StrategyData migrateAbilityScale(StrategyData strat,
      {bool force = false}) {
    if (!force && strat.versionNumber >= AbilityScaleMigration.version) {
      return strat;
    }

    final migratedPages = AbilityScaleMigration.migratePages(
      pages: strat.pages,
      map: strat.mapData,
    );

    final hasPageChanged = migratedPages.length == strat.pages.length &&
        migratedPages.asMap().entries.any((entry) {
          final index = entry.key;
          return entry.value != strat.pages[index];
        });

    if (!hasPageChanged && !force) {
      return strat;
    }

    return strat.copyWith(
      pages: migratedPages,
      versionNumber: Settings.versionNumber,
      lastEdited: DateTime.now(),
    );
  }

  static StrategyData migrateSquareAoeCenter(StrategyData strat,
      {bool force = false}) {
    if (!force && strat.versionNumber >= SquareAoeCenterMigration.version) {
      return strat;
    }

    final migratedPages = SquareAoeCenterMigration.migratePages(
      pages: strat.pages,
    );

    final hasPageChanged = migratedPages.length == strat.pages.length &&
        migratedPages.asMap().entries.any((entry) {
          final index = entry.key;
          return entry.value != strat.pages[index];
        });

    if (!hasPageChanged && !force) {
      return strat;
    }

    return strat.copyWith(
      pages: migratedPages,
      versionNumber: Settings.versionNumber,
      lastEdited: DateTime.now(),
    );
  }

  static StrategyData migrateCustomCircleWrapper(StrategyData strat,
      {bool force = false}) {
    if (!force && strat.versionNumber >= CustomCircleWrapperMigration.version) {
      return strat;
    }

    final migratedPages = CustomCircleWrapperMigration.migratePages(
      pages: strat.pages,
      map: strat.mapData,
    );

    final hasPageChanged = migratedPages.length == strat.pages.length &&
        migratedPages.asMap().entries.any((entry) {
          final index = entry.key;
          return entry.value != strat.pages[index];
        });

    if (!hasPageChanged && !force) {
      return strat;
    }

    return strat.copyWith(
      pages: migratedPages,
      versionNumber: Settings.versionNumber,
      lastEdited: DateTime.now(),
    );
  }

  static StrategyData migrateToCurrentVersion(StrategyData strat,
      {bool forceAbilityScale = false}) {
    final worldMigrated = migrateToWorld16x9(strat);
    final abilityScaleMigrated =
        migrateAbilityScale(worldMigrated, force: forceAbilityScale);
    final squareAoeMigrated = migrateSquareAoeCenter(abilityScaleMigrated);
    return migrateCustomCircleWrapper(squareAoeMigrated);
  }

  static Future<StrategyData> migrateLegacyData(StrategyData strat) async {
    // Already migrated
    if (strat.pages.isNotEmpty) {
      return migrateToCurrentVersion(strat);
    }
    if (strat.versionNumber > 15) {
      return migrateToCurrentVersion(strat);
    }
    final originalVersion = strat.versionNumber;
    // ignore: deprecated_member_use, deprecated_member_use_from_same_package
    final abilityData = [...strat.abilityData];
    if (strat.versionNumber < 7) {
      for (final a in abilityData) {
        if (a.data.abilityData! is SquareAbility) {
          a.position = a.position.translate(0, -7.5);
        }
      }
    }

    final firstPage = StrategyPage(
      id: const Uuid().v4(),
      name: "Page 1",
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      drawingData: [...strat.drawingData],
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      agentData: [...strat.agentData],
      abilityData: abilityData,
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      textData: [...strat.textData],
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      imageData: [...strat.imageData],
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      utilityData: [...strat.utilityData],
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      isAttack: strat.isAttack,
      // ignore: deprecated_member_use_from_same_package
      settings: strat.strategySettings,
      sortIndex: 0,
    );

    final updated = strat.copyWith(
      pages: [firstPage],
      agentData: [],
      abilityData: [],
      drawingData: [],
      utilityData: [],
      textData: [],
      versionNumber: Settings.versionNumber,
      lastEdited: DateTime.now(),
    );

    final worldMigrated = migrateToWorld16x9(updated,
        force: originalVersion < Settings.versionNumber);
    final abilityScaleMigrated = migrateAbilityScale(
      worldMigrated,
      force: originalVersion < AbilityScaleMigration.version,
    );
    final squareAoeMigrated = migrateSquareAoeCenter(
      abilityScaleMigrated,
      force: originalVersion < SquareAoeCenterMigration.version,
    );
    return migrateCustomCircleWrapper(
      squareAoeMigrated,
      force: originalVersion < CustomCircleWrapperMigration.version,
    );
  }

  static StrategyData migrateToWorld16x9(StrategyData strat,
      {bool force = false}) {
    if (!force && strat.versionNumber >= 38) return strat;

    const double normalizedHeight = 1000.0;
    const double mapAspectRatio = 1.24;
    const double worldAspectRatio = 16 / 9;
    const mapWidth = normalizedHeight * mapAspectRatio;
    const worldWidth = normalizedHeight * worldAspectRatio;
    const padding = (worldWidth - mapWidth) / 2;

    Offset shift(Offset offset) => offset.translate(padding, 0);

    List<PlacedAgentNode> shiftAgentNodes(List<PlacedAgentNode> agents) {
      return [
        for (final agent in agents)
          switch (agent) {
            PlacedAgent() => agent.copyWith(position: shift(agent.position))
              ..isDeleted = agent.isDeleted,
            PlacedViewConeAgent() =>
              agent.copyWith(position: shift(agent.position))
                ..isDeleted = agent.isDeleted,
            PlacedCircleAgent() =>
              agent.copyWith(position: shift(agent.position))
                ..isDeleted = agent.isDeleted,
          },
      ];
    }

    List<PlacedAbility> shiftAbilities(List<PlacedAbility> abilities) {
      return [
        for (final ability in abilities)
          ability.copyWith(position: shift(ability.position))
            ..isDeleted = ability.isDeleted
      ];
    }

    List<PlacedText> shiftTexts(List<PlacedText> texts) {
      return [
        for (final text in texts)
          text.copyWith(
            position: shift(text.position),
          )
      ];
    }

    List<PlacedImage> shiftImages(List<PlacedImage> images) {
      return [
        for (final image in images)
          image.copyWith(position: shift(image.position))
            ..isDeleted = image.isDeleted
      ];
    }

    List<PlacedUtility> shiftUtilities(List<PlacedUtility> utilities) {
      return [
        for (final utility in utilities)
          PlacedUtility(
            type: utility.type,
            position: shift(utility.position),
            id: utility.id,
            angle: utility.angle,
            customDiameter: utility.customDiameter,
            customWidth: utility.customWidth,
            customLength: utility.customLength,
            customColorValue: utility.customColorValue,
            customOpacityPercent: utility.customOpacityPercent,
          )
            ..rotation = utility.rotation
            ..length = utility.length
            ..isDeleted = utility.isDeleted
      ];
    }

    List<LineUp> shiftLineUps(List<LineUp> lineUps) {
      return [
        for (final lineUp in lineUps)
          () {
            final shiftedAgent = lineUp.agent.copyWith(
              position: shift(lineUp.agent.position),
            )..isDeleted = lineUp.agent.isDeleted;
            final shiftedAbility = lineUp.ability.copyWith(
              position: shift(lineUp.ability.position),
            )..isDeleted = lineUp.ability.isDeleted;
            return lineUp.copyWith(
              agent: shiftedAgent,
              ability: shiftedAbility,
            );
          }()
      ];
    }

    BoundingBox? shiftBoundingBox(BoundingBox? boundingBox) {
      if (boundingBox == null) return null;
      return BoundingBox(
        min: shift(boundingBox.min),
        max: shift(boundingBox.max),
      );
    }

    List<DrawingElement> shiftDrawings(List<DrawingElement> drawings) {
      return drawings
          .map((element) {
            if (element is Line) {
              return Line(
                lineStart: shift(element.lineStart),
                lineEnd: shift(element.lineEnd),
                color: element.color,
                thickness: element.thickness,
                boundingBox: shiftBoundingBox(element.boundingBox),
                isDotted: element.isDotted,
                hasArrow: element.hasArrow,
                id: element.id,
                showTraversalTime: element.showTraversalTime,
                traversalSpeedProfile: element.traversalSpeedProfile,
              );
            }
            if (element is FreeDrawing) {
              final shiftedPoints =
                  element.listOfPoints.map(shift).toList(growable: false);

              return FreeDrawing(
                listOfPoints: shiftedPoints,
                color: element.color,
                thickness: element.thickness,
                boundingBox: shiftBoundingBox(element.boundingBox),
                isDotted: element.isDotted,
                hasArrow: element.hasArrow,
                id: element.id,
                showTraversalTime: element.showTraversalTime,
                traversalSpeedProfile: element.traversalSpeedProfile,
              );
            }
            if (element is RectangleDrawing) {
              return RectangleDrawing(
                start: shift(element.start),
                end: shift(element.end),
                color: element.color,
                thickness: element.thickness,
                boundingBox: shiftBoundingBox(element.boundingBox),
                isDotted: element.isDotted,
                hasArrow: element.hasArrow,
                id: element.id,
              );
            }
            return element;
          })
          .cast<DrawingElement>()
          .toList(growable: false);
    }

    final updatedPages = strat.pages
        .map((page) => page.copyWith(
              sortIndex: page.sortIndex,
              name: page.name,
              id: page.id,
              agentData: shiftAgentNodes(page.agentData),
              abilityData: shiftAbilities(page.abilityData),
              textData: shiftTexts(page.textData),
              imageData: shiftImages(page.imageData),
              utilityData: shiftUtilities(page.utilityData),
              drawingData: shiftDrawings(page.drawingData),
              lineUps: shiftLineUps(page.lineUps),
            ))
        .toList(growable: false);

    final migrated = strat.copyWith(
      pages: updatedPages,
      versionNumber: Settings.versionNumber,
      lastEdited: DateTime.now(),
    );

    return migrated;
  }

  // Switch active page: flush old page first, then hydrate new
  Future<void> setActivePage(String pageID) async {
    if (pageID == activePageID) return;

    // Flush current before switching
    await _syncCurrentPageToHive();

    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final doc = box.get(state.id);
    if (doc == null) return;

    final page = doc.pages.firstWhere(
      (p) => p.id == pageID,
      orElse: () => doc.pages.first,
    );

    activePageID = page.id;
    state = state.copyWith(activePageId: page.id);

    ref.read(actionProvider.notifier).resetActionState();
    final migrated = migrateToCurrentVersion(doc);
    final migratedPage = migrated.pages.firstWhere(
      (p) => p.id == page.id,
      orElse: () => migrated.pages.first,
    );
    if (migrated != doc) {
      await box.put(migrated.id, migrated);
    }

    ref.read(agentProvider.notifier).fromHive(migratedPage.agentData);
    ref.read(abilityProvider.notifier).fromHive(migratedPage.abilityData);
    ref.read(drawingProvider.notifier).fromHive(migratedPage.drawingData);
    ref.read(textProvider.notifier).fromHive(migratedPage.textData);
    ref.read(placedImageProvider.notifier).fromHive(migratedPage.imageData);
    ref.read(utilityProvider.notifier).fromHive(migratedPage.utilityData);
    ref.read(mapProvider.notifier).setAttack(migratedPage.isAttack);
    ref.read(strategySettingsProvider.notifier).fromHive(migratedPage.settings);
    ref.read(strategyThemeProvider.notifier).fromStrategy(
          profileId: migrated.themeProfileId ??
              MapThemeProfilesProvider.immutableDefaultProfileId,
          overridePalette: migrated.themeOverridePalette,
        );
    ref.read(lineUpProvider.notifier).fromHive(migratedPage.lineUps);

    // Defer path rebuild until next frame (layout complete)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(drawingProvider.notifier)
          .rebuildAllPaths(CoordinateSystem.instance);
    });
  }

  Future<void> backwardPage() async {
    if (activePageID == null) return;

    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final doc = box.get(state.id);
    if (doc == null || doc.pages.isEmpty) return;

    // Order pages by their sortIndex to find the "leading" (next) page.
    final pages = [...doc.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));

    final currentIndex = pages.indexWhere((p) => p.id == activePageID);
    if (currentIndex == -1) return;
    int nextIndex = currentIndex - 1;
    if (nextIndex < 0)
      nextIndex = pages.length - 1; // No forward page available.

    final nextPage = pages[nextIndex];
    await setActivePageAnimated(
      nextPage.id,
      direction: PageTransitionDirection.backward,
    );
  }

  Future<void> forwardPage() async {
    if (activePageID == null) return;

    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final doc = box.get(state.id);
    if (doc == null || doc.pages.isEmpty) return;

    // Order pages by their sortIndex to find the "leading" (next) page.
    final pages = [...doc.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));

    final currentIndex = pages.indexWhere((p) => p.id == activePageID);
    if (currentIndex == -1) return;

    int nextIndex = currentIndex + 1;
    if (nextIndex >= pages.length) nextIndex = 0; // No forward page available.

    final nextPage = pages[nextIndex];
    await setActivePageAnimated(
      nextPage.id,
      direction: PageTransitionDirection.forward,
    );
  }

  Future<void> reorderPage(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;

    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final strat = box.get(state.id);
    if (strat == null || strat.pages.isEmpty) return;

    // `oldIndex`/`newIndex` are list positions from the UI (ReorderableListView),
    // not sortIndex values. We move the page and then reindex to keep a dense
    // 0..N-1 ordering.
    final ordered = [...strat.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));

    if (oldIndex < 0 ||
        oldIndex >= ordered.length ||
        newIndex < 0 ||
        newIndex > ordered.length) {
      return;
    }

    // Flutter ReorderableListView reports `newIndex` as the target index in the
    // list *after* the removal. When dragging down, we need to decrement.
    var targetIndex = newIndex;
    if (targetIndex > oldIndex) targetIndex -= 1;

    final moved = ordered.removeAt(oldIndex);
    ordered.insert(targetIndex, moved);

    final reindexed = [
      for (var i = 0; i < ordered.length; i++)
        ordered[i].copyWith(sortIndex: i),
    ];

    final updated =
        strat.copyWith(pages: reindexed, lastEdited: DateTime.now());
    await box.put(updated.id, updated);
  }

  PageTransitionDirection _resolveDirectionForPage(
      String pageID, List<StrategyPage> orderedPages) {
    if (activePageID == null) return PageTransitionDirection.forward;

    final currentIndex = orderedPages.indexWhere((p) => p.id == activePageID);
    final targetIndex = orderedPages.indexWhere((p) => p.id == pageID);
    if (currentIndex < 0 || targetIndex < 0) {
      return PageTransitionDirection.forward;
    }

    final length = orderedPages.length;
    final forwardSteps = (targetIndex - currentIndex + length) % length;
    final backwardSteps = (currentIndex - targetIndex + length) % length;
    return forwardSteps <= backwardSteps
        ? PageTransitionDirection.forward
        : PageTransitionDirection.backward;
  }

  // Add these inside StrategyProvider
  Future<void> setActivePageAnimated(String pageID,
      {PageTransitionDirection? direction,
      Duration duration = kPageTransitionDuration}) async {
    if (pageID == activePageID) return;

    final transitionState = ref.read(transitionProvider);
    final transitionNotifier = ref.read(transitionProvider.notifier);
    if (transitionState.active ||
        transitionState.phase == PageTransitionPhase.preparing) {
      transitionNotifier.complete();
    }

    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final doc = box.get(state.id);
    if (doc == null || doc.pages.isEmpty) return;

    final orderedPages = [...doc.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    final resolvedDirection =
        direction ?? _resolveDirectionForPage(pageID, orderedPages);
    final startSettings = ref.read(strategySettingsProvider);

    final prev = _snapshotAllPlaced();
    transitionNotifier.prepare(prev.values.toList(),
        direction: resolvedDirection,
        startAgentSize: startSettings.agentSize,
        startAbilitySize: startSettings.abilitySize);

    // Load target page (hydrates providers)
    await setActivePage(pageID);
    final endSettings = ref.read(strategySettingsProvider);

    // After layout, snapshot next and start transition
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final next = _snapshotAllPlaced();
      final entries = _diffToTransitions(prev, next);
      if (entries.isNotEmpty) {
        transitionNotifier.start(
          entries,
          duration: duration,
          direction: resolvedDirection,
          startAgentSize: startSettings.agentSize,
          endAgentSize: endSettings.agentSize,
          startAbilitySize: startSettings.abilitySize,
          endAbilitySize: endSettings.abilitySize,
        );
      } else {
        transitionNotifier.complete();
      }
    });
  }

  Map<String, PlacedWidget> _snapshotAllPlaced() {
    final map = <String, PlacedWidget>{};
    for (final a in ref.read(agentProvider)) map[a.id] = a;
    for (final ab in ref.read(abilityProvider)) map[ab.id] = ab;
    for (final t in ref.read(textProvider)) map[t.id] = t;
    for (final img in ref.read(placedImageProvider).images) map[img.id] = img;
    for (final u in ref.read(utilityProvider)) map[u.id] = u;
    return map;
  }

  List<PageTransitionEntry> _diffToTransitions(
    Map<String, PlacedWidget> prev,
    Map<String, PlacedWidget> next,
  ) {
    final entries = <PageTransitionEntry>[];
    var order = 0;

    // Move / appear
    next.forEach((id, to) {
      final from = prev[id];
      if (from != null) {
        if (from.position != to.position ||
            PageTransitionEntry.rotationOf(from) !=
                PageTransitionEntry.rotationOf(to) ||
            PageTransitionEntry.lengthOf(from) !=
                PageTransitionEntry.lengthOf(to) ||
            !listEquals(
              PageTransitionEntry.armLengthsOf(from),
              PageTransitionEntry.armLengthsOf(to),
            ) ||
            PageTransitionEntry.scaleOf(from) !=
                PageTransitionEntry.scaleOf(to) ||
            PageTransitionEntry.textSizeOf(from) !=
                PageTransitionEntry.textSizeOf(to) ||
            PageTransitionEntry.agentStateOf(from) !=
                PageTransitionEntry.agentStateOf(to) ||
            PageTransitionEntry.customDiameterOf(from) !=
                PageTransitionEntry.customDiameterOf(to) ||
            PageTransitionEntry.customWidthOf(from) !=
                PageTransitionEntry.customWidthOf(to) ||
            PageTransitionEntry.customLengthOf(from) !=
                PageTransitionEntry.customLengthOf(to)) {
          entries
              .add(PageTransitionEntry.move(from: from, to: to, order: order));
        } else {
          // Unchanged: include as 'none' so it stays visible while base view is hidden
          entries.add(PageTransitionEntry.none(to: to, order: order));
        }
      } else {
        entries.add(PageTransitionEntry.appear(to: to, order: order));
      }
      order++;
    });

    // Disappear
    prev.forEach((id, from) {
      if (!next.containsKey(id)) {
        entries.add(PageTransitionEntry.disappear(from: from, order: order));
        order++;
      }
    });

    return entries;
  }

  Future<void> addPage([String? name]) async {
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);

    // Flush current page so its edits are not lost
    await _syncCurrentPageToHive();

    final strat = box.get(state.id);
    if (strat == null) return;

    name ??= "Page ${strat.pages.length + 1}";
    //TODO Make this function of the index
    final newPage = strat.pages.last.copyWith(
      id: const Uuid().v4(),
      name: name,
      sortIndex: strat.pages.length,
    );

    // final newPage = StrategyPage(
    //   id: const Uuid().v4(),
    //   name: name,
    //   drawingData: ,
    //   agentData: const [],
    //   abilityData: const [],
    //   textData: const [],
    //   imageData: const [],
    //   utilityData: const [],
    //   sortIndex: strat.pages.length, // corrected
    // );

    final updated = strat.copyWith(
      pages: [...strat.pages, newPage],
      lastEdited: DateTime.now(),
    );
    await box.put(updated.id, updated);

    await setActivePageAnimated(newPage.id);
  }

  Future<void> loadFromHive(String id) async {
    final newStrat = Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .values
        .where((StrategyData strategy) {
      return strategy.id == id;
    }).firstOrNull;

    if (newStrat == null) {
      return;
    }
    ref.read(actionProvider.notifier).resetActionState();

    List<PlacedImage> pageImageData = [];
    for (final page in newStrat.pages) {
      pageImageData.addAll(page.imageData);
    }
    if (!kIsWeb) {
      List<String> allImageIds = [];
      for (final page in newStrat.pages) {
        allImageIds.addAll(page.imageData.map((image) => image.id));
        for (final lineUp in page.lineUps) {
          List<String> lineUpImages = [];
          lineUpImages.addAll(lineUp.images.map((image) => image.id));
          allImageIds.addAll(lineUpImages);
        }
      }
      await ref
          .read(placedImageProvider.notifier)
          .deleteUnusedImages(newStrat.id, allImageIds);
    }

    // We clear previous data to avoid artifacts when loading a new strategy
    final migratedStrategy = migrateToCurrentVersion(newStrat);
    final page = migratedStrategy.pages.first;

    if (migratedStrategy != newStrat) {
      await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
          .put(migratedStrategy.id, migratedStrategy);
    }

    ref.read(agentProvider.notifier).fromHive(page.agentData);
    ref.read(abilityProvider.notifier).fromHive(page.abilityData);
    ref.read(drawingProvider.notifier).fromHive(page.drawingData);

    ref
        .read(mapProvider.notifier)
        .fromHive(migratedStrategy.mapData, page.isAttack);
    ref.read(textProvider.notifier).fromHive(page.textData);
    ref.read(placedImageProvider.notifier).fromHive(page.imageData);
    ref.read(lineUpProvider.notifier).fromHive(page.lineUps);
    ref.read(strategySettingsProvider.notifier).fromHive(page.settings);
    ref.read(strategyThemeProvider.notifier).fromStrategy(
          profileId: migratedStrategy.themeProfileId ??
              MapThemeProfilesProvider.immutableDefaultProfileId,
          overridePalette: migratedStrategy.themeOverridePalette,
        );
    ref.read(utilityProvider.notifier).fromHive(page.utilityData);
    activePageID = page.id;

    if (kIsWeb) {
      state = StrategyState(
        isSaved: true,
        stratName: migratedStrategy.name,
        id: migratedStrategy.id,
        storageDirectory: null,
        activePageId: page.id,
      );
      return;
    }
    final newDir = await setStorageDirectory(migratedStrategy.id);

    state = StrategyState(
      isSaved: true,
      stratName: migratedStrategy.name,
      id: migratedStrategy.id,
      storageDirectory: newDir.path,
      activePageId: page.id,
    );
  }

  Future<void> loadFromFilePath(String filePath) async {
    await _importStrategyFile(
      file: XFile(filePath),
      targetFolderId: null,
    );
  }

  Future<void> loadFromFilePicker() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: ["ica"],
    );

    if (result == null) return;

    for (PlatformFile file in result.files) {
      await _importStrategyFile(
        file: file.xFile,
        targetFolderId: null,
      );
    }
  }

  Future<ImportBatchResult> importBackupFromFilePicker() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );

    if (result == null || result.files.isEmpty) {
      return const ImportBatchResult.empty();
    }

    final PlatformFile pickedFile = result.files.single;
    final String? filePath = pickedFile.path;

    if (filePath == null || filePath.isEmpty) {
      // FilePicker can return files without a valid path (e.g. in-memory bytes).
      // In that case, return an empty result instead of throwing.
      return const ImportBatchResult.empty();
    }

    return _importZipArchive(
      zipFile: File(filePath),
      parentFolderId: null,
    );
  }

  Future<ImportBatchResult> loadFromFileDrop(List<XFile> files) async {
    final targetFolderId = ref.read(folderProvider);
    var result = const ImportBatchResult.empty();

    for (XFile file in files) {
      result = result.merge(
        await _importDroppedItem(
          file: file,
          targetFolderId: targetFolderId,
        ),
      );
    }

    return result;
  }

  Future<Directory> getTempDirectory(String strategyID) async {
    String tempDirectoryPath;
    try {
      tempDirectoryPath = (await getTemporaryDirectory()).path;
    } on MissingPluginException {
      tempDirectoryPath = Directory.systemTemp.path;
    } on MissingPlatformDirectoryException {
      tempDirectoryPath = Directory.systemTemp.path;
    }

    Directory tempDir = await Directory(
            path.join(tempDirectoryPath, "xyz_icarus_strats", strategyID))
        .create(recursive: true);
    return tempDir;
  }

  Future<void> cleanUpTempDirectory(String strategyID) async {
    final tempDirectory = await getTempDirectory(strategyID);
    await tempDirectory.delete(recursive: true);
  }

  Future<Directory> _getApplicationSupportDirectoryOrSystemTemp() async {
    try {
      return await getApplicationSupportDirectory();
    } on MissingPluginException {
      return Directory.systemTemp;
    } on MissingPlatformDirectoryException {
      return Directory.systemTemp;
    }
  }

  Future<void> _extractArchiveEntriesToDisk({
    required Archive archive,
    required Directory destination,
  }) async {
    // Normalize the destination path once for comparisons.
    final String destinationPath = path.normalize(destination.path);

    for (final entry in archive) {
      final normalizedName = normalizeArchivePath(entry.name);
      if (normalizedName.isEmpty) {
        continue;
      }

      // Reject absolute paths in the archive entry name.
      if (path.isAbsolute(normalizedName)) {
        continue;
      }

      // Reject any entry that attempts directory traversal using "..".
      final segments = path.posix.split(normalizedName);
      if (segments.any((segment) => segment == '..')) {
        continue;
      }

      // Build the target path under the destination directory.
      final targetPath = path.joinAll([
        destinationPath,
        ...segments,
      ]);

      // Normalize and verify that the target path stays within destination.
      final normalizedTargetPath = path.normalize(targetPath);
      final bool isWithinDestination =
          path.isWithin(destinationPath, normalizedTargetPath) ||
              normalizedTargetPath == destinationPath;
      if (!isWithinDestination) {
        continue;
      }

      if (entry.isFile) {
        final targetFile = File(normalizedTargetPath);
        await targetFile.parent.create(recursive: true);
        await targetFile.writeAsBytes(entry.content as List<int>);
      } else {
        await Directory(normalizedTargetPath).create(recursive: true);
      }
    }
  }

  /// Returns true if the file is a ZIP (by checking the magic number)
  Future<bool> isZipFile(File file) async {
    // Read the first 4 bytes of the file
    final raf = file.openSync(mode: FileMode.read);
    final header = raf.readSync(4);
    await raf.close();

    // ZIP files start with 'PK\x03\x04'
    return header.length == 4 &&
        header[0] == 0x50 && // 'P'
        header[1] == 0x4B && // 'K'
        header[2] == 0x03 &&
        header[3] == 0x04;
  }

  Future<ImportBatchResult> _importDroppedItem({
    required XFile file,
    required String? targetFolderId,
  }) async {
    if (file.path.isEmpty) {
      return const ImportBatchResult(
        strategiesImported: 0,
        foldersCreated: 0,
        themeProfilesImported: 0,
        globalStateRestored: false,
        issues: [
          ImportIssue(path: '', code: ImportIssueCode.ioError),
        ],
      );
    }

    try {
      final entityType =
          await FileSystemEntity.type(file.path, followLinks: false);
      switch (entityType) {
        case FileSystemEntityType.directory:
          return await _importDirectoryTree(
            sourceDir: Directory(file.path),
            parentFolderId: targetFolderId,
          );
        case FileSystemEntityType.file:
          final extension = path.extension(file.path).toLowerCase();
          if (extension == '.ica') {
            await _importStrategyFile(
              file: file,
              targetFolderId: targetFolderId,
            );
            return const ImportBatchResult(
              strategiesImported: 1,
              foldersCreated: 0,
              themeProfilesImported: 0,
              globalStateRestored: false,
              issues: [],
            );
          }

          if (await isZipFile(File(file.path))) {
            return await _importZipArchive(
              zipFile: File(file.path),
              parentFolderId: targetFolderId,
            );
          }

          return ImportBatchResult(
            strategiesImported: 0,
            foldersCreated: 0,
            themeProfilesImported: 0,
            globalStateRestored: false,
            issues: [
              ImportIssue(
                path: file.path,
                code: ImportIssueCode.unsupportedFile,
              ),
            ],
          );
        case FileSystemEntityType.notFound:
        case FileSystemEntityType.link:
        case FileSystemEntityType.unixDomainSock:
        case FileSystemEntityType.pipe:
        default:
          return ImportBatchResult(
            strategiesImported: 0,
            foldersCreated: 0,
            themeProfilesImported: 0,
            globalStateRestored: false,
            issues: [
              ImportIssue(
                path: file.path,
                code: ImportIssueCode.ioError,
              ),
            ],
          );
      }
    } on NewerVersionImportException {
      return ImportBatchResult(
        strategiesImported: 0,
        foldersCreated: 0,
        themeProfilesImported: 0,
        globalStateRestored: false,
        issues: [
          ImportIssue(
            path: file.path,
            code: ImportIssueCode.newerVersion,
          ),
        ],
      );
    } catch (error, stackTrace) {
      _reportImportFailure(
        'Failed to import dropped item ${file.path}.',
        error: error,
        stackTrace: stackTrace,
        source: 'StrategyProvider._importDroppedItem',
      );
      return ImportBatchResult(
        strategiesImported: 0,
        foldersCreated: 0,
        themeProfilesImported: 0,
        globalStateRestored: false,
        issues: [
          ImportIssue(
            path: file.path,
            code: ImportIssueCode.ioError,
          ),
        ],
      );
    }
  }

  Future<Folder> _createImportedFolder({
    required String name,
    required String? parentFolderId,
  }) {
    return ref.read(folderProvider.notifier).createFolder(
          name: name,
          icon: Icons.drive_folder_upload,
          color: FolderColor.generic,
          parentID: parentFolderId,
        );
  }

  List<FileSystemEntity> _sortedImportEntities(
    Iterable<FileSystemEntity> entities,
  ) {
    final filtered = entities.where((entity) {
      final basename = path.basename(entity.path);
      return !_shouldIgnoreImportedEntityName(basename);
    }).toList();
    filtered.sort((a, b) => a.path.compareTo(b.path));
    return filtered;
  }

  bool _shouldIgnoreImportedEntityName(String name) {
    return name.isEmpty ||
        name == '__MACOSX' ||
        name == '.DS_Store' ||
        name == archiveMetadataFileName ||
        name.startsWith('._');
  }

  bool _isIcaFileEntity(FileSystemEntity entity) {
    return entity is File &&
        path.extension(entity.path).toLowerCase() == '.ica';
  }

  Future<_ImportEntityListing> _listImportEntities(Directory directory) async {
    final issues = <ImportIssue>[];
    try {
      final entities = directory.listSync(followLinks: false);
      return _ImportEntityListing(
        entities: _sortedImportEntities(entities),
        issues: issues,
      );
    } on FileSystemException catch (error, stackTrace) {
      final errorPath = _resolveImportErrorPath(error, directory.path);
      _reportImportFailure(
        'Failed to list import directory $errorPath.',
        error: error,
        stackTrace: stackTrace,
        source: 'StrategyProvider._listImportEntities',
      );
      issues.add(
        ImportIssue(
          path: errorPath,
          code: ImportIssueCode.ioError,
        ),
      );
    }

    return _ImportEntityListing(
      entities: const [],
      issues: issues,
    );
  }

  String _resolveImportErrorPath(Object error, String fallbackPath) {
    if (error is FileSystemException) {
      return error.path ?? fallbackPath;
    }
    return fallbackPath;
  }

  Future<ImportBatchResult> _importEntitiesIntoFolder({
    required Iterable<FileSystemEntity> entities,
    required String parentFolderId,
  }) async {
    var result = const ImportBatchResult.empty();
    final sortedEntities = _sortedImportEntities(entities);

    for (final entity in sortedEntities) {
      if (entity is Directory) {
        result = result.merge(
          await _importDirectoryTree(
            sourceDir: entity,
            parentFolderId: parentFolderId,
          ),
        );
        continue;
      }

      if (_isIcaFileEntity(entity)) {
        try {
          await _importStrategyFile(
            file: XFile(entity.path),
            targetFolderId: parentFolderId,
          );
          result = result.merge(
            const ImportBatchResult(
              strategiesImported: 1,
              foldersCreated: 0,
              themeProfilesImported: 0,
              globalStateRestored: false,
              issues: [],
            ),
          );
        } on NewerVersionImportException {
          result = result.merge(
            ImportBatchResult(
              strategiesImported: 0,
              foldersCreated: 0,
              themeProfilesImported: 0,
              globalStateRestored: false,
              issues: [
                ImportIssue(
                  path: entity.path,
                  code: ImportIssueCode.newerVersion,
                ),
              ],
            ),
          );
        } catch (error, stackTrace) {
          _reportImportFailure(
            'Failed to import strategy file ${entity.path}.',
            error: error,
            stackTrace: stackTrace,
            source: 'StrategyProvider._importEntitiesIntoFolder',
          );
          result = result.merge(
            ImportBatchResult(
              strategiesImported: 0,
              foldersCreated: 0,
              themeProfilesImported: 0,
              globalStateRestored: false,
              issues: [
                ImportIssue(
                  path: entity.path,
                  code: ImportIssueCode.invalidStrategy,
                ),
              ],
            ),
          );
        }
        continue;
      }

      result = result.merge(
        ImportBatchResult(
          strategiesImported: 0,
          foldersCreated: 0,
          themeProfilesImported: 0,
          globalStateRestored: false,
          issues: [
            ImportIssue(
              path: entity.path,
              code: ImportIssueCode.unsupportedFile,
            ),
          ],
        ),
      );
    }

    return result;
  }

  Future<ImportBatchResult> _importDirectoryTree({
    required Directory sourceDir,
    required String? parentFolderId,
  }) async {
    final manifestFile =
        File(path.join(sourceDir.path, archiveMetadataFileName));
    _ManifestImportData? manifestData;
    if (await manifestFile.exists()) {
      try {
        manifestData = await _loadManifestIfPresent(sourceDir);
        if (manifestData != null) {
          _validateArchiveManifest(manifestData);
        }
      } catch (error, stackTrace) {
        _reportImportFailure(
          'Failed to import manifest archive from ${sourceDir.path}.',
          error: error,
          stackTrace: stackTrace,
          source: 'StrategyProvider._importDirectoryTree',
        );
        return ImportBatchResult(
          strategiesImported: 0,
          foldersCreated: 0,
          themeProfilesImported: 0,
          globalStateRestored: false,
          issues: [
            ImportIssue(
              path: manifestFile.path,
              code: ImportIssueCode.invalidArchiveMetadata,
            ),
          ],
        ).merge(
          await _importDirectoryTreeLegacy(
            sourceDir: sourceDir,
            parentFolderId: parentFolderId,
          ),
        );
      }
    }

    if (manifestData != null) {
      return _importManifestArchive(
        manifestData: manifestData,
        parentFolderId: parentFolderId,
      );
    }

    return _importDirectoryTreeLegacy(
      sourceDir: sourceDir,
      parentFolderId: parentFolderId,
    );
  }

  Future<ImportBatchResult> _importDirectoryTreeLegacy({
    required Directory sourceDir,
    required String? parentFolderId,
  }) async {
    final importedFolder = await _createImportedFolder(
      name: path.basename(sourceDir.path),
      parentFolderId: parentFolderId,
    );

    var result = const ImportBatchResult(
      strategiesImported: 0,
      foldersCreated: 1,
      themeProfilesImported: 0,
      globalStateRestored: false,
      issues: [],
    );

    final listing = await _listImportEntities(sourceDir);
    if (listing.issues.isNotEmpty) {
      result = result.merge(
        ImportBatchResult(
          strategiesImported: 0,
          foldersCreated: 0,
          themeProfilesImported: 0,
          globalStateRestored: false,
          issues: listing.issues,
        ),
      );
    }

    result = result.merge(
      await _importEntitiesIntoFolder(
        entities: listing.entities,
        parentFolderId: importedFolder.id,
      ),
    );

    return result;
  }

  Future<ImportBatchResult> _importZipArchive({
    required File zipFile,
    required String? parentFolderId,
  }) async {
    final archive = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    _ZipManifestData? manifestData;
    try {
      manifestData = _loadManifestFromArchive(archive);
      if (manifestData != null) {
        _validateArchiveManifestFromZip(manifestData);
      }
    } catch (error, stackTrace) {
      _reportImportFailure(
        'Failed to import manifest zip ${zipFile.path}.',
        error: error,
        stackTrace: stackTrace,
        source: 'StrategyProvider._importZipArchive',
      );
      return ImportBatchResult(
        strategiesImported: 0,
        foldersCreated: 0,
        themeProfilesImported: 0,
        globalStateRestored: false,
        issues: [
          ImportIssue(
            path: zipFile.path,
            code: ImportIssueCode.invalidArchiveMetadata,
          ),
        ],
      ).merge(
        await _importLegacyZipArchiveFromEntries(
          archive: archive,
          parentFolderId: parentFolderId,
          zipFileName: path.basenameWithoutExtension(zipFile.path),
        ),
      );
    }

    if (manifestData != null) {
      return _importManifestArchiveFromZip(
        manifestData: manifestData,
        parentFolderId: parentFolderId,
      );
    }

    return _importLegacyZipArchiveFromEntries(
      archive: archive,
      parentFolderId: parentFolderId,
      zipFileName: path.basenameWithoutExtension(zipFile.path),
    );
  }

  _ZipManifestData? _loadManifestFromArchive(Archive archive) {
    final filesByPath = <String, ArchiveFile>{};
    for (final entry in archive) {
      if (!entry.isFile) {
        continue;
      }
      filesByPath[normalizeArchivePath(entry.name)] = entry;
    }

    final manifestPaths = filesByPath.keys
        .where((pathValue) =>
            path.posix.basename(pathValue) == archiveMetadataFileName)
        .toList(growable: false);
    if (manifestPaths.isEmpty) {
      return null;
    }
    if (manifestPaths.length > 1) {
      throw const FormatException('Archive contains multiple manifest files');
    }

    final manifestArchivePath = manifestPaths.single;
    final manifestEntry = filesByPath[manifestArchivePath]!;
    final decoded = jsonDecode(utf8.decode(_archiveFileBytes(manifestEntry)));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Archive manifest must decode to an object');
    }

    final rootPrefix = path.posix.dirname(manifestArchivePath);
    return _ZipManifestData(
      manifest: ArchiveManifest.fromJson(decoded),
      rootPrefix: rootPrefix == '.' ? '' : rootPrefix,
      filesByPath: filesByPath,
      manifestArchivePath: manifestArchivePath,
    );
  }

  List<int> _archiveFileBytes(ArchiveFile entry) {
    return entry.content as List<int>;
  }

  Future<File> _writeArchiveEntryToTempFile({
    required ArchiveFile archiveFile,
    required Directory tempDirectory,
  }) async {
    final baseName = path.basename(normalizeArchivePath(archiveFile.name));
    final file = File(path.join(tempDirectory.path, baseName));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(_archiveFileBytes(archiveFile));
    return file;
  }

  Future<ImportBatchResult> _importManifestArchiveFromZip({
    required _ZipManifestData manifestData,
    required String? parentFolderId,
  }) async {
    var result = const ImportBatchResult.empty();
    var profileIdRemap = const <String, String>{};

    if (manifestData.manifest.archiveType == ArchiveType.libraryBackup) {
      final globals = manifestData.manifest.globals;
      if (globals == null) {
        throw const FormatException(
            'Library backup archive is missing globals');
      }
      final globalImportResult = await _importArchiveGlobals(globals);
      profileIdRemap = globalImportResult.profileIdRemap;
      result = result.merge(
        ImportBatchResult(
          strategiesImported: 0,
          foldersCreated: 0,
          themeProfilesImported: globalImportResult.themeProfilesImported,
          globalStateRestored: globalImportResult.globalStateRestored,
          issues: const [],
        ),
      );
    }

    final folderEntries = [...manifestData.manifest.folders]..sort((a, b) {
        final depthCompare = _archivePathDepth(a.archivePath)
            .compareTo(_archivePathDepth(b.archivePath));
        if (depthCompare != 0) {
          return depthCompare;
        }
        return a.archivePath.compareTo(b.archivePath);
      });

    final localFolderIdsByManifestId = <String, String>{};
    for (final folderEntry in folderEntries) {
      final resolvedParentFolderId = folderEntry.parentManifestId == null
          ? (manifestData.manifest.archiveType == ArchiveType.folderTree
              ? parentFolderId
              : null)
          : localFolderIdsByManifestId[folderEntry.parentManifestId!];
      if (folderEntry.parentManifestId != null &&
          resolvedParentFolderId == null) {
        throw FormatException(
          'Missing parent folder mapping for ${folderEntry.manifestId}',
        );
      }

      final createdFolder =
          await ref.read(folderProvider.notifier).createFolder(
                name: folderEntry.name,
                icon: folderEntry.icon.toIconData(),
                color: folderEntry.color,
                customColor: folderEntry.customColorValue == null
                    ? null
                    : Color(folderEntry.customColorValue!),
                parentID: resolvedParentFolderId,
              );
      localFolderIdsByManifestId[folderEntry.manifestId] = createdFolder.id;
      result = result.merge(
        const ImportBatchResult(
          strategiesImported: 0,
          foldersCreated: 1,
          themeProfilesImported: 0,
          globalStateRestored: false,
          issues: [],
        ),
      );
    }

    final materializedDirectory =
        await Directory.systemTemp.createTemp('icarus-zip-manifest-import');
    try {
      for (final strategyEntry in [...manifestData.manifest.strategies]
        ..sort((a, b) => a.archivePath.compareTo(b.archivePath))) {
        final targetFolderId = strategyEntry.folderManifestId == null
            ? null
            : localFolderIdsByManifestId[strategyEntry.folderManifestId!];
        final archivePath = _zipArchiveAbsolutePath(
          rootPrefix: manifestData.rootPrefix,
          relativePath: strategyEntry.archivePath,
        );
        final archiveFile = manifestData.filesByPath[archivePath];
        if (archiveFile == null) {
          throw FormatException('Missing strategy file: $archivePath');
        }

        try {
          final tempFile = await _writeArchiveEntryToTempFile(
            archiveFile: archiveFile,
            tempDirectory: materializedDirectory,
          );
          await _importStrategyFile(
            file: XFile(tempFile.path),
            targetFolderId: targetFolderId,
            displayNameOverride: strategyEntry.name,
            themeProfileIdRemap: profileIdRemap,
          );
          result = result.merge(
            const ImportBatchResult(
              strategiesImported: 1,
              foldersCreated: 0,
              themeProfilesImported: 0,
              globalStateRestored: false,
              issues: [],
            ),
          );
        } on NewerVersionImportException {
          result = result.merge(
            ImportBatchResult(
              strategiesImported: 0,
              foldersCreated: 0,
              themeProfilesImported: 0,
              globalStateRestored: false,
              issues: [
                ImportIssue(
                  path: archivePath,
                  code: ImportIssueCode.newerVersion,
                ),
              ],
            ),
          );
        } catch (error, stackTrace) {
          _reportImportFailure(
            'Failed to import manifest strategy $archivePath.',
            error: error,
            stackTrace: stackTrace,
            source: 'StrategyProvider._importManifestArchiveFromZip',
          );
          result = result.merge(
            ImportBatchResult(
              strategiesImported: 0,
              foldersCreated: 0,
              themeProfilesImported: 0,
              globalStateRestored: false,
              issues: [
                ImportIssue(
                  path: archivePath,
                  code: ImportIssueCode.invalidStrategy,
                ),
              ],
            ),
          );
        }
      }
    } finally {
      try {
        await materializedDirectory.delete(recursive: true);
      } catch (_) {}
    }

    final undeclaredIssues = _collectUndeclaredZipArchiveIssues(manifestData);
    if (undeclaredIssues.isNotEmpty) {
      result = result.merge(
        ImportBatchResult(
          strategiesImported: 0,
          foldersCreated: 0,
          themeProfilesImported: 0,
          globalStateRestored: false,
          issues: undeclaredIssues,
        ),
      );
    }

    return result;
  }

  void _validateArchiveManifestFromZip(_ZipManifestData manifestData) {
    final manifest = manifestData.manifest;
    final folderIds = <String>{};
    final folderPaths = <String>{};
    final rootFolders = <ArchiveFolderEntry>[];

    for (final folder in manifest.folders) {
      if (!folderIds.add(folder.manifestId)) {
        throw FormatException(
            'Duplicate folder manifest ID: ${folder.manifestId}');
      }
      if (!folderPaths.add(folder.archivePath)) {
        throw FormatException(
            'Duplicate folder archive path: ${folder.archivePath}');
      }
      if (folder.parentManifestId == null) {
        rootFolders.add(folder);
      } else if (!manifest.folders.any(
          (candidate) => candidate.manifestId == folder.parentManifestId)) {
        throw FormatException('Missing parent folder for ${folder.manifestId}');
      }
    }

    if (manifest.archiveType == ArchiveType.folderTree) {
      if (rootFolders.length != 1) {
        throw const FormatException(
            'Folder tree archives must contain one root');
      }
      if (rootFolders.single.archivePath.isNotEmpty) {
        throw const FormatException(
          'Folder tree root folder must use the manifest root path',
        );
      }
    }

    final knownFolderIds =
        manifest.folders.map((folder) => folder.manifestId).toSet();
    final strategyPaths = <String>{};
    for (final strategy in manifest.strategies) {
      if (!strategyPaths.add(strategy.archivePath)) {
        throw FormatException(
          'Duplicate strategy archive path: ${strategy.archivePath}',
        );
      }
      if (strategy.folderManifestId != null &&
          !knownFolderIds.contains(strategy.folderManifestId)) {
        throw FormatException(
          'Unknown strategy folder reference: ${strategy.folderManifestId}',
        );
      }
      if (manifest.archiveType == ArchiveType.folderTree &&
          strategy.folderManifestId == null) {
        throw const FormatException(
          'Folder tree strategies must reference the exported root folder',
        );
      }
      final archivePath = _zipArchiveAbsolutePath(
        rootPrefix: manifestData.rootPrefix,
        relativePath: strategy.archivePath,
      );
      if (!manifestData.filesByPath.containsKey(archivePath)) {
        throw FormatException('Missing strategy file: $archivePath');
      }
    }
  }

  String _zipArchiveAbsolutePath({
    required String rootPrefix,
    required String relativePath,
  }) {
    return normalizeArchivePath(
      rootPrefix.isEmpty
          ? relativePath
          : path.posix.join(rootPrefix, relativePath),
    );
  }

  List<ImportIssue> _collectUndeclaredZipArchiveIssues(
    _ZipManifestData manifestData,
  ) {
    final allowedFiles = <String>{manifestData.manifestArchivePath};
    for (final strategy in manifestData.manifest.strategies) {
      allowedFiles.add(
        _zipArchiveAbsolutePath(
          rootPrefix: manifestData.rootPrefix,
          relativePath: strategy.archivePath,
        ),
      );
    }

    final issues = <ImportIssue>[];
    for (final archivePath in manifestData.filesByPath.keys) {
      if (!allowedFiles.contains(archivePath) &&
          !_shouldIgnoreImportedEntityName(path.posix.basename(archivePath))) {
        issues.add(
          ImportIssue(
            path: archivePath,
            code: ImportIssueCode.unsupportedFile,
          ),
        );
      }
    }
    return issues;
  }

  Future<ImportBatchResult> _importLegacyZipArchiveFromEntries({
    required Archive archive,
    required String? parentFolderId,
    required String zipFileName,
  }) async {
    final filesByPath = <String, ArchiveFile>{};
    for (final entry in archive) {
      if (!entry.isFile) {
        continue;
      }
      final normalizedPath = normalizeArchivePath(entry.name);
      if (_shouldIgnoreImportedEntityName(
          path.posix.basename(normalizedPath))) {
        continue;
      }
      filesByPath[normalizedPath] = entry;
    }

    final topLevelSegments = <String>{};
    final looseTopLevelIca = <String>[];
    for (final archivePath in filesByPath.keys) {
      final segments = archivePath.split('/');
      if (segments.isEmpty) {
        continue;
      }
      topLevelSegments.add(segments.first);
      if (segments.length == 1 &&
          path.extension(archivePath).toLowerCase() == '.ica') {
        looseTopLevelIca.add(archivePath);
      }
    }

    if (topLevelSegments.length == 1 && looseTopLevelIca.isEmpty) {
      return _importLegacyZipDirectory(
        directoryPrefix: topLevelSegments.single,
        filesByPath: filesByPath,
        parentFolderId: parentFolderId,
      );
    }

    final wrapperFolder = await _createImportedFolder(
      name: zipFileName,
      parentFolderId: parentFolderId,
    );

    return const ImportBatchResult(
      strategiesImported: 0,
      foldersCreated: 1,
      themeProfilesImported: 0,
      globalStateRestored: false,
      issues: [],
    ).merge(
      await _importLegacyZipEntitiesIntoFolder(
        parentPrefix: '',
        filesByPath: filesByPath,
        parentFolderId: wrapperFolder.id,
      ),
    );
  }

  Future<ImportBatchResult> _importLegacyZipDirectory({
    required String directoryPrefix,
    required Map<String, ArchiveFile> filesByPath,
    required String? parentFolderId,
  }) async {
    final importedFolder = await _createImportedFolder(
      name: path.posix.basename(directoryPrefix),
      parentFolderId: parentFolderId,
    );

    return const ImportBatchResult(
      strategiesImported: 0,
      foldersCreated: 1,
      themeProfilesImported: 0,
      globalStateRestored: false,
      issues: [],
    ).merge(
      await _importLegacyZipEntitiesIntoFolder(
        parentPrefix: directoryPrefix,
        filesByPath: filesByPath,
        parentFolderId: importedFolder.id,
      ),
    );
  }

  Future<ImportBatchResult> _importLegacyZipEntitiesIntoFolder({
    required String parentPrefix,
    required Map<String, ArchiveFile> filesByPath,
    required String parentFolderId,
  }) async {
    final directDirectories = <String>{};
    final directFiles = <String>[];
    final normalizedParentPrefix = normalizeArchivePath(parentPrefix);

    for (final archivePath in filesByPath.keys) {
      final parentPath = path.posix.dirname(archivePath);
      if (normalizedParentPrefix.isEmpty) {
        if (parentPath == '.') {
          directFiles.add(archivePath);
        } else if (!parentPath.contains('/')) {
          directDirectories.add(parentPath);
        }
        continue;
      }

      if (parentPath == normalizedParentPrefix) {
        directFiles.add(archivePath);
        continue;
      }

      if (archivePath.startsWith('$normalizedParentPrefix/')) {
        final remainder =
            archivePath.substring(normalizedParentPrefix.length + 1);
        if (remainder.isEmpty || !remainder.contains('/')) {
          continue;
        }
        final childDirectory = remainder.substring(0, remainder.indexOf('/'));
        directDirectories.add(
          normalizeArchivePath(
            path.posix.join(normalizedParentPrefix, childDirectory),
          ),
        );
      }
    }

    var result = const ImportBatchResult.empty();

    final tempDirectory =
        await Directory.systemTemp.createTemp('icarus-zip-legacy-import');
    try {
      final sortedDirectories = directDirectories.toList()..sort();
      for (final directoryPrefix in sortedDirectories) {
        result = result.merge(
          await _importLegacyZipDirectory(
            directoryPrefix: directoryPrefix,
            filesByPath: filesByPath,
            parentFolderId: parentFolderId,
          ),
        );
      }

      directFiles.sort();
      for (final archivePath in directFiles) {
        if (path.extension(archivePath).toLowerCase() != '.ica') {
          result = result.merge(
            ImportBatchResult(
              strategiesImported: 0,
              foldersCreated: 0,
              themeProfilesImported: 0,
              globalStateRestored: false,
              issues: [
                ImportIssue(
                  path: archivePath,
                  code: ImportIssueCode.unsupportedFile,
                ),
              ],
            ),
          );
          continue;
        }

        try {
          final tempFile = await _writeArchiveEntryToTempFile(
            archiveFile: filesByPath[archivePath]!,
            tempDirectory: tempDirectory,
          );
          await _importStrategyFile(
            file: XFile(tempFile.path),
            targetFolderId: parentFolderId,
          );
          result = result.merge(
            const ImportBatchResult(
              strategiesImported: 1,
              foldersCreated: 0,
              themeProfilesImported: 0,
              globalStateRestored: false,
              issues: [],
            ),
          );
        } on NewerVersionImportException {
          result = result.merge(
            ImportBatchResult(
              strategiesImported: 0,
              foldersCreated: 0,
              themeProfilesImported: 0,
              globalStateRestored: false,
              issues: [
                ImportIssue(
                  path: archivePath,
                  code: ImportIssueCode.newerVersion,
                ),
              ],
            ),
          );
        } catch (error, stackTrace) {
          _reportImportFailure(
            'Failed to import zip strategy $archivePath.',
            error: error,
            stackTrace: stackTrace,
            source: 'StrategyProvider._importLegacyZipEntitiesIntoFolder',
          );
          result = result.merge(
            ImportBatchResult(
              strategiesImported: 0,
              foldersCreated: 0,
              themeProfilesImported: 0,
              globalStateRestored: false,
              issues: [
                ImportIssue(
                  path: archivePath,
                  code: ImportIssueCode.invalidStrategy,
                ),
              ],
            ),
          );
        }
      }
    } finally {
      try {
        await tempDirectory.delete(recursive: true);
      } catch (_) {}
    }

    return result;
  }

  Future<_ManifestImportData?> _loadManifestIfPresent(
      Directory directory) async {
    final manifestFile =
        File(path.join(directory.path, archiveMetadataFileName));
    if (!await manifestFile.exists()) {
      return null;
    }

    final raw = await manifestFile.readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Archive metadata must decode to an object');
    }

    return _ManifestImportData(
      rootDirectory: directory,
      manifestFile: manifestFile,
      manifest: ArchiveManifest.fromJson(decoded),
    );
  }

  Future<ImportBatchResult> _importManifestArchive({
    required _ManifestImportData manifestData,
    required String? parentFolderId,
  }) async {
    _validateArchiveManifest(manifestData);

    var result = const ImportBatchResult.empty();
    var profileIdRemap = const <String, String>{};

    if (manifestData.manifest.archiveType == ArchiveType.libraryBackup) {
      final globals = manifestData.manifest.globals;
      if (globals == null) {
        throw const FormatException(
            'Library backup archive is missing globals');
      }
      final globalImportResult = await _importArchiveGlobals(globals);
      profileIdRemap = globalImportResult.profileIdRemap;
      result = result.merge(
        ImportBatchResult(
          strategiesImported: 0,
          foldersCreated: 0,
          themeProfilesImported: globalImportResult.themeProfilesImported,
          globalStateRestored: globalImportResult.globalStateRestored,
          issues: const [],
        ),
      );
    }

    final folderEntries = [...manifestData.manifest.folders]..sort((a, b) {
        final depthCompare = _archivePathDepth(a.archivePath)
            .compareTo(_archivePathDepth(b.archivePath));
        if (depthCompare != 0) {
          return depthCompare;
        }
        return a.archivePath.compareTo(b.archivePath);
      });

    final localFolderIdsByManifestId = <String, String>{};
    for (final folderEntry in folderEntries) {
      final resolvedParentFolderId = folderEntry.parentManifestId == null
          ? (manifestData.manifest.archiveType == ArchiveType.folderTree
              ? parentFolderId
              : null)
          : localFolderIdsByManifestId[folderEntry.parentManifestId!];
      if (folderEntry.parentManifestId != null &&
          resolvedParentFolderId == null) {
        throw FormatException(
          'Missing parent folder mapping for ${folderEntry.manifestId}',
        );
      }

      final createdFolder =
          await ref.read(folderProvider.notifier).createFolder(
                name: folderEntry.name,
                icon: folderEntry.icon.toIconData(),
                color: folderEntry.color,
                customColor: folderEntry.customColorValue == null
                    ? null
                    : Color(folderEntry.customColorValue!),
                parentID: resolvedParentFolderId,
              );
      localFolderIdsByManifestId[folderEntry.manifestId] = createdFolder.id;
      result = result.merge(
        const ImportBatchResult(
          strategiesImported: 0,
          foldersCreated: 1,
          themeProfilesImported: 0,
          globalStateRestored: false,
          issues: [],
        ),
      );
    }

    final strategyEntries = [...manifestData.manifest.strategies]
      ..sort((a, b) => a.archivePath.compareTo(b.archivePath));
    for (final strategyEntry in strategyEntries) {
      final targetFolderId = strategyEntry.folderManifestId == null
          ? null
          : localFolderIdsByManifestId[strategyEntry.folderManifestId!];
      if (strategyEntry.folderManifestId != null && targetFolderId == null) {
        throw FormatException(
          'Missing folder mapping for strategy ${strategyEntry.archivePath}',
        );
      }

      try {
        await _importStrategyFile(
          file: XFile(
            _archivePathToFile(
                    manifestData.rootDirectory, strategyEntry.archivePath)
                .path,
          ),
          targetFolderId: targetFolderId,
          displayNameOverride: strategyEntry.name,
          themeProfileIdRemap: profileIdRemap,
        );
        result = result.merge(
          const ImportBatchResult(
            strategiesImported: 1,
            foldersCreated: 0,
            themeProfilesImported: 0,
            globalStateRestored: false,
            issues: [],
          ),
        );
      } on NewerVersionImportException {
        result = result.merge(
          ImportBatchResult(
            strategiesImported: 0,
            foldersCreated: 0,
            themeProfilesImported: 0,
            globalStateRestored: false,
            issues: [
              ImportIssue(
                path: strategyEntry.archivePath,
                code: ImportIssueCode.newerVersion,
              ),
            ],
          ),
        );
      } catch (error, stackTrace) {
        _reportImportFailure(
          'Failed to import manifest strategy ${strategyEntry.archivePath}.',
          error: error,
          stackTrace: stackTrace,
          source: 'StrategyProvider._importManifestArchive',
        );
        result = result.merge(
          ImportBatchResult(
            strategiesImported: 0,
            foldersCreated: 0,
            themeProfilesImported: 0,
            globalStateRestored: false,
            issues: [
              ImportIssue(
                path: strategyEntry.archivePath,
                code: ImportIssueCode.invalidStrategy,
              ),
            ],
          ),
        );
      }
    }

    final undeclaredIssues = await _collectUndeclaredArchiveIssues(
      manifestData: manifestData,
    );
    if (undeclaredIssues.isNotEmpty) {
      result = result.merge(
        ImportBatchResult(
          strategiesImported: 0,
          foldersCreated: 0,
          themeProfilesImported: 0,
          globalStateRestored: false,
          issues: undeclaredIssues,
        ),
      );
    }

    return result;
  }

  void _validateArchiveManifest(_ManifestImportData manifestData) {
    final manifest = manifestData.manifest;
    final folderIds = <String>{};
    final folderPaths = <String>{};
    final rootFolders = <ArchiveFolderEntry>[];

    for (final folder in manifest.folders) {
      if (!folderIds.add(folder.manifestId)) {
        throw FormatException(
            'Duplicate folder manifest ID: ${folder.manifestId}');
      }
      if (!folderPaths.add(folder.archivePath)) {
        throw FormatException(
            'Duplicate folder archive path: ${folder.archivePath}');
      }
      if (folder.parentManifestId == null) {
        rootFolders.add(folder);
      } else if (!manifest.folders.any(
          (candidate) => candidate.manifestId == folder.parentManifestId)) {
        throw FormatException('Missing parent folder for ${folder.manifestId}');
      }
    }

    if (manifest.archiveType == ArchiveType.folderTree) {
      if (rootFolders.length != 1) {
        throw const FormatException(
            'Folder tree archives must contain one root');
      }
      if (rootFolders.single.archivePath.isNotEmpty) {
        throw const FormatException(
          'Folder tree root folder must use the manifest root path',
        );
      }
    }

    final knownFolderIds =
        manifest.folders.map((folder) => folder.manifestId).toSet();
    final strategyPaths = <String>{};
    for (final strategy in manifest.strategies) {
      if (!strategyPaths.add(strategy.archivePath)) {
        throw FormatException(
          'Duplicate strategy archive path: ${strategy.archivePath}',
        );
      }
      if (strategy.folderManifestId != null &&
          !knownFolderIds.contains(strategy.folderManifestId)) {
        throw FormatException(
          'Unknown strategy folder reference: ${strategy.folderManifestId}',
        );
      }
      if (manifest.archiveType == ArchiveType.folderTree &&
          strategy.folderManifestId == null) {
        throw const FormatException(
          'Folder tree strategies must reference the exported root folder',
        );
      }
      if (!(_archivePathToFile(manifestData.rootDirectory, strategy.archivePath)
          .existsSync())) {
        throw FormatException('Missing strategy file: ${strategy.archivePath}');
      }
    }
  }

  int _archivePathDepth(String archivePath) {
    if (archivePath.isEmpty) {
      return 0;
    }
    return archivePath.split('/').length;
  }

  File _archivePathToFile(Directory rootDirectory, String archivePath) {
    final normalized = normalizeArchivePath(archivePath);
    final segments =
        normalized.isEmpty ? const <String>[] : normalized.split('/');
    return File(path.joinAll([rootDirectory.path, ...segments]));
  }

  Future<List<ImportIssue>> _collectUndeclaredArchiveIssues({
    required _ManifestImportData manifestData,
  }) async {
    final allowedFiles = <String>{archiveMetadataFileName};
    final allowedDirectories = <String>{};

    void addAllowedDirectoryAncestors(String archivePath) {
      var current = normalizeArchivePath(archivePath);
      if (current.isEmpty) {
        return;
      }
      while (current.isNotEmpty && current != '.') {
        allowedDirectories.add(current);
        final parent = path.posix.dirname(current);
        if (parent == '.' || parent == current) {
          break;
        }
        current = parent;
      }
    }

    for (final folder in manifestData.manifest.folders) {
      addAllowedDirectoryAncestors(folder.archivePath);
    }
    for (final strategy in manifestData.manifest.strategies) {
      final normalizedPath = normalizeArchivePath(strategy.archivePath);
      allowedFiles.add(normalizedPath);
      final parentDirectory = path.posix.dirname(normalizedPath);
      if (parentDirectory != '.') {
        addAllowedDirectoryAncestors(parentDirectory);
      }
    }

    final issues = <ImportIssue>[];
    await for (final entity in manifestData.rootDirectory
        .list(recursive: true, followLinks: false)) {
      final relativePath = normalizeArchivePath(
        path.relative(entity.path, from: manifestData.rootDirectory.path),
      );
      if (relativePath.isEmpty) {
        continue;
      }

      if (entity is File) {
        if (!allowedFiles.contains(relativePath)) {
          issues.add(
            ImportIssue(
              path: entity.path,
              code: ImportIssueCode.unsupportedFile,
            ),
          );
        }
        continue;
      }

      final directoryAllowed = allowedDirectories.contains(relativePath) ||
          allowedFiles.any((allowed) => allowed.startsWith('$relativePath/'));
      if (!directoryAllowed) {
        issues.add(
          ImportIssue(
            path: entity.path,
            code: ImportIssueCode.unsupportedFile,
          ),
        );
      }
    }

    return issues;
  }

  Future<_GlobalImportResult> _importArchiveGlobals(
      ArchiveGlobals globals) async {
    await MapThemeProfilesProvider.bootstrap();

    final profileBox =
        Hive.box<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    final appPreferencesBox =
        Hive.box<AppPreferences>(HiveBoxNames.appPreferencesBox);
    final favoriteAgentsBox = Hive.box<bool>(HiveBoxNames.favoriteAgentsBox);

    final profileIdRemap = <String, String>{};
    var themeProfilesImported = 0;

    final existingProfiles = profileBox.values.toList();
    for (final importedProfile in globals.themeProfiles) {
      if (importedProfile.isBuiltIn) {
        if (profileBox.get(importedProfile.id) != null) {
          profileIdRemap[importedProfile.id] = importedProfile.id;
        }
        continue;
      }

      final matchingExisting = existingProfiles.firstWhere(
        (existing) =>
            !existing.isBuiltIn &&
            existing.name == importedProfile.name &&
            existing.palette == importedProfile.palette,
        orElse: () => MapThemeProfile(
          id: '',
          name: '',
          palette: MapThemeProfilesProvider.immutableDefaultPalette,
          isBuiltIn: false,
        ),
      );

      if (matchingExisting.id.isNotEmpty) {
        profileIdRemap[importedProfile.id] = matchingExisting.id;
        continue;
      }

      var localProfileId = importedProfile.id;
      if (profileBox.get(localProfileId) != null ||
          MapThemeProfilesProvider.immutableBuiltInProfiles
              .any((profile) => profile.id == localProfileId)) {
        localProfileId = const Uuid().v4();
      }

      final createdProfile = MapThemeProfile(
        id: localProfileId,
        name: importedProfile.name,
        palette: importedProfile.palette,
        isBuiltIn: false,
      );
      await profileBox.put(createdProfile.id, createdProfile);
      existingProfiles.add(createdProfile);
      profileIdRemap[importedProfile.id] = createdProfile.id;
      themeProfilesImported++;
    }

    final resolvedDefaultProfileId = globals
                .defaultThemeProfileIdForNewStrategies ==
            null
        ? MapThemeProfilesProvider.immutableDefaultProfileId
        : profileIdRemap[globals.defaultThemeProfileIdForNewStrategies!] ??
            (profileBox.get(globals.defaultThemeProfileIdForNewStrategies!) !=
                    null
                ? globals.defaultThemeProfileIdForNewStrategies!
                : MapThemeProfilesProvider.immutableDefaultProfileId);

    await appPreferencesBox.put(
      MapThemeProfilesProvider.appPreferencesSingletonKey,
      AppPreferences(
        defaultThemeProfileIdForNewStrategies: resolvedDefaultProfileId,
      ),
    );

    await favoriteAgentsBox.clear();
    for (final favorite in globals.favoriteAgentTypes()) {
      await favoriteAgentsBox.put(favorite.name, true);
    }

    await ref.read(mapThemeProfilesProvider.notifier).refreshFromHive();
    ref.invalidate(favoriteAgentsProvider);

    return _GlobalImportResult(
      themeProfilesImported: themeProfilesImported,
      globalStateRestored: true,
      profileIdRemap: profileIdRemap,
    );
  }

  Future<void> _importStrategyFile({
    required XFile file,
    required String? targetFolderId,
    String? displayNameOverride,
    Map<String, String> themeProfileIdRemap = const {},
  }) async {
    final newID = const Uuid().v4();
    final bool isZip = await isZipFile(File(file.path));

    log("Is ZIP file: $isZip");
    final bytes = await file.readAsBytes();
    String jsonData = "";

    try {
      if (isZip) {
        // Decode the Zip file
        final archive = ZipDecoder().decodeBytes(bytes);

        final imageFolder = await PlacedImageProvider.getImageFolder(newID);
        final tempDirectory = await getTempDirectory(newID);

        await _extractArchiveEntriesToDisk(
          archive: archive,
          destination: tempDirectory,
        );

        final tempDirectoryList = tempDirectory.listSync();
        log("Temp directory list: ${tempDirectoryList.length}.");

        for (final fileEntity in tempDirectoryList) {
          if (fileEntity is File) {
            log(fileEntity.path);
            if (path.extension(fileEntity.path) == ".json") {
              log("Found JSON file");
              jsonData = await fileEntity.readAsString();
            } else if (path.extension(fileEntity.path) != ".ica") {
              final fileName = path.basename(fileEntity.path);
              await fileEntity.copy(path.join(imageFolder.path, fileName));
            }
          }
        }
        if (jsonData.isEmpty) {
          throw Exception("No .ica file found");
        }
      } else {
        jsonData = await file.readAsString();
      }

      Map<String, dynamic> json = jsonDecode(jsonData);
      final versionNumber = int.tryParse(json["versionNumber"].toString()) ??
          Settings.versionNumber;
      _throwIfImportedVersionIsTooNew(versionNumber);

      //Backwards compatibility for pre-pages exported strategies
      final List<DrawingElement> drawingData =
          DrawingProvider.fromJson(jsonEncode(json["drawingData"] ?? []));

      final List<PlacedAgent> agentData =
          AgentProvider.fromJson(jsonEncode(json["agentData"] ?? []))
              .whereType<PlacedAgent>()
              .toList(growable: false);

      final List<PlacedAbility> abilityData =
          AbilityProvider.fromJson(jsonEncode(json["abilityData"] ?? []));

      final mapData = MapProvider.fromJson(jsonEncode(json["mapData"]));
      final textData =
          TextProvider.fromJson(jsonEncode(json["textData"] ?? []));

      List<PlacedImage> imageData = [];
      if (!kIsWeb) {
        if (isZip) {
          imageData = await PlacedImageProvider.fromJson(
              jsonString: jsonEncode(json["imageData"] ?? []),
              strategyID: newID);
        } else {
          log('Legacy image data loading');
          imageData = await PlacedImageProvider.legacyFromJson(
              jsonString: jsonEncode(json["imageData"] ?? []),
              strategyID: newID);
        }
      }

      final StrategySettings settingsData;
      final bool isAttack;
      final List<PlacedUtility> utilityData;

      if (json["settingsData"] != null) {
        settingsData = ref
            .read(strategySettingsProvider.notifier)
            .fromJson(jsonEncode(json["settingsData"]));
      } else {
        settingsData = StrategySettings();
      }

      if (json["isAttack"] != null) {
        isAttack = json["isAttack"] == "true" ? true : false;
      } else {
        isAttack = true;
      }

      if (json["utilityData"] != null) {
        utilityData = UtilityProvider.fromJson(jsonEncode(json["utilityData"]));
      } else {
        utilityData = [];
      }
      final MapThemePalette? importedThemeOverridePalette =
          json["themePalette"] is Map<String, dynamic>
              ? MapThemePalette.fromJson(json["themePalette"])
              : (json["themePalette"] is Map
                  ? MapThemePalette.fromJson(
                      Map<String, dynamic>.from(json["themePalette"]))
                  : null);
      final rawImportedThemeProfileId = json['themeProfileId'];
      final importedThemeProfileId = rawImportedThemeProfileId is String &&
              rawImportedThemeProfileId.isNotEmpty
          ? rawImportedThemeProfileId
          : null;
      final String? resolvedThemeProfileId = importedThemeProfileId == null
          ? null
          : (themeProfileIdRemap[importedThemeProfileId] ??
              importedThemeProfileId);

      // bool needsMigration = (versionNumber < 15);
      final List<StrategyPage> pages = json["pages"] != null
          ? await StrategyPage.listFromJson(
              json: jsonEncode(json["pages"]),
              strategyID: newID,
              isZip: isZip,
            )
          : [];

      StrategyData newStrategy = StrategyData(
        // ignore: deprecated_member_use_from_same_package, deprecated_member_use
        drawingData: drawingData,
        // ignore: deprecated_member_use_from_same_package, deprecated_member_use
        agentData: agentData,
        // ignore: deprecated_member_use_from_same_package, deprecated_member_use
        abilityData: abilityData,
        // ignore: deprecated_member_use_from_same_package, deprecated_member_use
        textData: textData,
        // ignore: deprecated_member_use_from_same_package, deprecated_member_use
        imageData: imageData,
        // ignore: deprecated_member_use_from_same_package, deprecated_member_use
        utilityData: utilityData,
        // ignore: deprecated_member_use_from_same_package, deprecated_member_use
        isAttack: isAttack,
        // ignore: deprecated_member_use_from_same_package, deprecated_member_use
        strategySettings: settingsData,

        pages: pages,
        id: newID,
        name: displayNameOverride ?? path.basenameWithoutExtension(file.name),
        mapData: mapData,
        versionNumber: versionNumber,
        lastEdited: DateTime.now(),

        folderID: targetFolderId,
        themeProfileId: resolvedThemeProfileId,
        themeOverridePalette: resolvedThemeProfileId == null
            ? importedThemeOverridePalette
            : null,
      );

      newStrategy = await migrateLegacyData(newStrategy);

      await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
          .put(newStrategy.id, newStrategy);
    } finally {
      if (isZip) {
        try {
          await cleanUpTempDirectory(newID);
        } catch (_) {}
      }
    }
  }

  static bool isNewerVersionImportError(Object error) {
    return error is NewerVersionImportException;
  }

  @visibleForTesting
  static void throwIfImportedVersionIsTooNewForTest(int importedVersion) {
    _throwIfImportedVersionIsTooNew(importedVersion);
  }

  static void _throwIfImportedVersionIsTooNew(int importedVersion) {
    if (importedVersion <= Settings.versionNumber) {
      return;
    }

    throw NewerVersionImportException(
      importedVersion: importedVersion,
      currentVersion: Settings.versionNumber,
    );
  }

  Future<String> createNewStrategy(String name) async {
    final newID = const Uuid().v4();
    final pageID = const Uuid().v4();
    final defaultThemeProfileId =
        ref.read(mapThemeProfilesProvider).defaultProfileIdForNewStrategies;
    final newStrategy = StrategyData(
      mapData: MapValue.ascent,
      versionNumber: Settings.versionNumber,
      id: newID,
      name: name,
      pages: [
        StrategyPage(
          id: pageID,
          name: "Page 1",
          drawingData: [],
          agentData: [],
          abilityData: [],
          textData: [],
          imageData: [],
          utilityData: [],
          lineUps: [],
          sortIndex: 0,
          isAttack: true,
          settings: StrategySettings(),
        )
      ],
      lastEdited: DateTime.now(),

      // ignore: deprecated_member_use_from_same_package
      strategySettings: StrategySettings(),
      folderID: ref.read(folderProvider),
      themeProfileId: defaultThemeProfileId,
    );

    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .put(newStrategy.id, newStrategy);

    return newStrategy.id;
  }

  void setThemeProfileForCurrentStrategy(String profileId) {
    ref.read(strategyThemeProvider.notifier).setProfile(profileId);
    setUnsaved();
  }

  void setThemeOverrideForCurrentStrategy(MapThemePalette palette) {
    ref.read(strategyThemeProvider.notifier).setOverride(palette);
    setUnsaved();
  }

  void clearThemeOverrideForCurrentStrategy() {
    ref.read(strategyThemeProvider.notifier).clearOverride();
    setUnsaved();
  }

  Future<void> _flushCurrentStrategyIfNeeded() async {
    if (state.stratName == null || state.id == 'testID') {
      return;
    }
    await forceSaveNow(state.id);
  }

  Future<void> exportFolder(String folderID) async {
    final folder = Hive.box<Folder>(HiveBoxNames.foldersBox).get(folderID);
    if (folder == null) {
      log("Couldn't find folder to export");
      return;
    }

    await _flushCurrentStrategyIfNeeded();
    final stagingDirectory = await buildFolderExportDirectoryForTest(folderID);

    try {
      final outputFile = await FilePicker.platform.saveFile(
        type: FileType.custom,
        dialogTitle: 'Please select an output file:',
        fileName: "${sanitizeFileName(folder.name)}.zip",
        allowedExtensions: ['zip'],
      );

      if (outputFile == null) return;

      final encoder = ZipFileEncoder();
      encoder.create(outputFile);
      await encoder.addDirectory(stagingDirectory, includeDirName: false);
      await encoder.close();
    } finally {
      try {
        await stagingDirectory.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> exportLibrary() async {
    await _flushCurrentStrategyIfNeeded();
    final stagingDirectory = await buildLibraryExportDirectoryForTest();

    try {
      final outputFile = await FilePicker.platform.saveFile(
        type: FileType.custom,
        dialogTitle: 'Please select an output file:',
        fileName: _buildLibraryBackupFileName(DateTime.now()),
        allowedExtensions: ['zip'],
      );

      if (outputFile == null) return;

      final encoder = ZipFileEncoder();
      encoder.create(outputFile);
      await encoder.addDirectory(stagingDirectory, includeDirName: false);
      await encoder.close();
    } finally {
      try {
        await stagingDirectory.delete(recursive: true);
      } catch (_) {}
    }
  }

  @visibleForTesting
  Future<Directory> buildFolderExportDirectoryForTest(String folderID) async {
    final folder = Hive.box<Folder>(HiveBoxNames.foldersBox).get(folderID);
    if (folder == null) {
      throw StateError("Couldn't find folder to export");
    }

    final stagingDirectory =
        await Directory.systemTemp.createTemp('icarus-folder-export');
    final rootDirectory = await _createUniqueChildDirectory(
      parentDirectory: stagingDirectory,
      desiredName: folder.name,
    );
    final exportState = _ArchiveExportState(rootDirectory: rootDirectory);
    await _writeFolderArchive(
      folderID: folderID,
      exportDirectory: rootDirectory,
      exportState: exportState,
      parentManifestId: null,
      currentArchivePath: '',
    );
    await _writeArchiveManifest(
      exportState: exportState,
      archiveType: ArchiveType.folderTree,
    );
    return stagingDirectory;
  }

  @visibleForTesting
  Future<Directory> buildLibraryExportDirectoryForTest() async {
    final stagingDirectory =
        await Directory.systemTemp.createTemp('icarus-library-export');
    final rootDirectory = Directory(
      path.join(stagingDirectory.path, libraryBackupRootDirectoryName),
    );
    await rootDirectory.create(recursive: true);
    final rootStrategiesDirectory =
        Directory(path.join(rootDirectory.path, 'root_strategies'))
          ..createSync(recursive: true);
    final foldersDirectory = Directory(path.join(rootDirectory.path, 'folders'))
      ..createSync(recursive: true);

    final exportState = _ArchiveExportState(rootDirectory: rootDirectory);

    for (final strategy in _sortedStrategiesForFolder(null)) {
      final strategyArchivePath = await zipStrategy(
        id: strategy.id,
        saveDir: rootStrategiesDirectory,
      );
      exportState.strategies.add(
        ArchiveStrategyEntry(
          name: strategy.name,
          archivePath: normalizeArchivePath(path.posix.join(
            'root_strategies',
            path.basename(strategyArchivePath),
          )),
          folderManifestId: null,
        ),
      );
    }

    for (final rootFolder in _sortedFoldersForParent(null)) {
      final rootFolderDirectory = await _createUniqueChildDirectory(
        parentDirectory: foldersDirectory,
        desiredName: rootFolder.name,
      );
      final rootArchivePath = normalizeArchivePath(path.posix.join(
        'folders',
        path.basename(rootFolderDirectory.path),
      ));
      await _writeFolderArchive(
        folderID: rootFolder.id,
        exportDirectory: rootFolderDirectory,
        exportState: exportState,
        parentManifestId: null,
        currentArchivePath: rootArchivePath,
      );
    }

    await _writeArchiveManifest(
      exportState: exportState,
      archiveType: ArchiveType.libraryBackup,
      globals: _buildLibraryGlobals(),
    );
    return stagingDirectory;
  }

  Future<Directory> _createUniqueChildDirectory({
    required Directory parentDirectory,
    required String desiredName,
  }) async {
    final sanitizedName = sanitizeFileName(desiredName);
    var candidate = sanitizedName;
    var counter = 1;
    var directory = Directory(path.join(parentDirectory.path, candidate));
    while (await directory.exists()) {
      candidate = '${sanitizedName}_$counter';
      counter++;
      directory = Directory(path.join(parentDirectory.path, candidate));
    }
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> _writeFolderArchive({
    required String folderID,
    required Directory exportDirectory,
    required _ArchiveExportState exportState,
    required String? parentManifestId,
    required String currentArchivePath,
  }) async {
    final currentFolder =
        ref.read(folderProvider.notifier).findFolderByID(folderID);
    if (currentFolder == null) {
      return;
    }

    final manifestId = const Uuid().v4();
    exportState.folders.add(
      ArchiveFolderEntry(
        manifestId: manifestId,
        name: currentFolder.name,
        parentManifestId: parentManifestId,
        archivePath: normalizeArchivePath(currentArchivePath),
        icon: ArchiveIconDescriptor.fromIconData(currentFolder.icon),
        color: currentFolder.color,
        customColorValue: currentFolder.customColor?.toARGB32(),
      ),
    );

    for (final strategy in _sortedStrategiesForFolder(folderID)) {
      final strategyArchivePath = await zipStrategy(
        id: strategy.id,
        saveDir: exportDirectory,
      );
      exportState.strategies.add(
        ArchiveStrategyEntry(
          name: strategy.name,
          archivePath: normalizeArchivePath(path.posix.join(
            currentArchivePath,
            path.basename(strategyArchivePath),
          )),
          folderManifestId: manifestId,
        ),
      );
    }

    for (final subFolder in _sortedFoldersForParent(folderID)) {
      final childDirectory = await _createUniqueChildDirectory(
        parentDirectory: exportDirectory,
        desiredName: subFolder.name,
      );
      final childArchivePath = normalizeArchivePath(path.posix.join(
        currentArchivePath,
        path.basename(childDirectory.path),
      ));
      await _writeFolderArchive(
        folderID: subFolder.id,
        exportDirectory: childDirectory,
        exportState: exportState,
        parentManifestId: manifestId,
        currentArchivePath: childArchivePath,
      );
    }
  }

  static String sanitizeFileName(String input) {
    final sanitized = input.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    return sanitized.isEmpty ? 'untitled' : sanitized;
  }

  String _buildLibraryBackupFileName(DateTime timestamp) {
    String twoDigit(int value) => value.toString().padLeft(2, '0');
    return 'icarus-library-backup-'
        '${timestamp.year}-${twoDigit(timestamp.month)}-${twoDigit(timestamp.day)}_'
        '${twoDigit(timestamp.hour)}-${twoDigit(timestamp.minute)}-${twoDigit(timestamp.second)}.zip';
  }

  List<StrategyData> _sortedStrategiesForFolder(String? folderID) {
    final strategies = Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .values
        .where((strategy) => strategy.folderID == folderID)
        .toList();
    strategies.sort((a, b) {
      final nameCompare = a.name.compareTo(b.name);
      if (nameCompare != 0) {
        return nameCompare;
      }
      return a.id.compareTo(b.id);
    });
    return strategies;
  }

  List<Folder> _sortedFoldersForParent(String? parentID) {
    final folders = Hive.box<Folder>(HiveBoxNames.foldersBox)
        .values
        .where((folder) => folder.parentID == parentID)
        .toList();
    folders.sort((a, b) {
      final nameCompare = a.name.compareTo(b.name);
      if (nameCompare != 0) {
        return nameCompare;
      }
      return a.id.compareTo(b.id);
    });
    return folders;
  }

  ArchiveGlobals _buildLibraryGlobals() {
    final profiles = Hive.box<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox)
        .values
        .map(
          (profile) => ArchiveThemeProfileEntry(
            id: profile.id,
            name: profile.name,
            palette: profile.palette,
            isBuiltIn: profile.isBuiltIn,
          ),
        )
        .toList(growable: false);
    final appPreferences =
        Hive.box<AppPreferences>(HiveBoxNames.appPreferencesBox)
            .get(MapThemeProfilesProvider.appPreferencesSingletonKey);
    final favoriteAgents = Hive.box<bool>(HiveBoxNames.favoriteAgentsBox)
        .keys
        .whereType<String>()
        .toList()
      ..sort();

    return ArchiveGlobals(
      themeProfiles: profiles,
      defaultThemeProfileIdForNewStrategies:
          appPreferences?.defaultThemeProfileIdForNewStrategies,
      favoriteAgents: favoriteAgents,
    );
  }

  Future<void> _writeArchiveManifest({
    required _ArchiveExportState exportState,
    required ArchiveType archiveType,
    ArchiveGlobals? globals,
  }) async {
    final manifest = ArchiveManifest(
      schemaVersion: archiveManifestSchemaVersion,
      archiveType: archiveType,
      exportedAt: DateTime.now().toUtc(),
      appVersionNumber: Settings.versionNumber,
      folders: exportState.folders,
      strategies: exportState.strategies,
      globals: globals,
    );

    final manifestFile = File(
        path.join(exportState.rootDirectory.path, archiveMetadataFileName));
    await manifestFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
    );
  }

  MapThemePalette _resolveThemePaletteForExport(StrategyData strategy) {
    if (strategy.themeOverridePalette != null) {
      return strategy.themeOverridePalette!;
    }

    final profiles =
        Hive.box<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    final assignedProfile = strategy.themeProfileId == null
        ? null
        : profiles.get(strategy.themeProfileId!);
    if (assignedProfile != null) {
      return assignedProfile.palette;
    }

    return MapThemeProfilesProvider.immutableDefaultPalette;
  }

  Future<String> zipStrategy({
    required String id,
    Directory? saveDir,
    String? outputFilePath,
  }) async {
    final strategy = Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(id);
    if (strategy == null) {
      log("Couldn't find strategy to export");
      throw StateError("Couldn't find strategy to export");
    }

    final payload = {
      "versionNumber": "${Settings.versionNumber}",
      "mapData": "${Maps.mapNames[strategy.mapData]}",
      "themePalette": _resolveThemePaletteForExport(strategy).toJson(),
      if (strategy.themeProfileId != null)
        "themeProfileId": strategy.themeProfileId,
      "pages": strategy.pages.map((page) => page.toJson(strategy.id)).toList(),
    };
    final data = jsonEncode(payload);

    final sanitizedStrategyName = sanitizeFileName(strategy.name);

    late final String outPath;
    late final String archiveBase;
    if (outputFilePath != null) {
      outPath = outputFilePath;
      archiveBase = path.basenameWithoutExtension(outPath);
    } else {
      final base = sanitizedStrategyName;
      var candidate = base;
      var index = 1;
      while (File(path.join(saveDir!.path, "$candidate.ica")).existsSync()) {
        candidate = "${base}_$index";
        index++;
      }
      archiveBase = candidate;
      outPath = path.join(saveDir.path, "$archiveBase.ica");
    }

    final jsonArchiveFile =
        ArchiveFile.bytes("$archiveBase.json", utf8.encode(data));

    final zipEncoder = ZipFileEncoder()..create(outPath);

    final supportDirectory =
        await _getApplicationSupportDirectoryOrSystemTemp();
    final customDirectory =
        Directory(path.join(supportDirectory.path, strategy.id));
    final imagesDirectory =
        Directory(path.join(customDirectory.path, 'images'));
    await imagesDirectory.create(recursive: true);

    await for (final entity in imagesDirectory.list()) {
      if (entity is File) {
        await zipEncoder.addFile(entity);
      }
    }

    zipEncoder.addArchiveFile(jsonArchiveFile);
    await zipEncoder.close();
    return outPath;
  }

  Future<void> exportFile(String id) async {
    await forceSaveNow(id);

    final outputFile = await FilePicker.platform.saveFile(
      type: FileType.custom,
      dialogTitle: 'Please select an output file:',
      fileName: "${sanitizeFileName(state.stratName ?? "new strategy")}.ica",
      allowedExtensions: ["ica"],
    );

    if (outputFile == null) return;
    await zipStrategy(id: id, outputFilePath: outputFile);
  }

  Future<void> renameStrategy(String strategyID, String newName) async {
    final strategyBox = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final strategy = strategyBox.get(strategyID);

    if (strategy != null) {
      strategy.name = newName;
      await strategy.save();
      if (state.id == strategyID) {
        state = state.copyWith(stratName: newName);
      }
    } else {
      log("Strategy with ID $strategyID not found.");
    }
  }

  Future<void> duplicateStrategy(String strategyID) async {
    final strategyBox = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final originalStrategy = strategyBox.get(strategyID);
    if (originalStrategy == null) {
      log("Original strategy with ID $strategyID not found.");
      return;
    }
    final newPages = originalStrategy.pages
        .map((page) => page.copyWith(id: const Uuid().v4()))
        .toList();

    final newID = const Uuid().v4();

    final duplicatedStrategy = StrategyData(
      id: newID,
      name: "${originalStrategy.name} (Copy)",
      mapData: originalStrategy
          .mapData, // MapValue is likely an enum, so this should be safe
      versionNumber: originalStrategy.versionNumber,
      lastEdited: DateTime.now(),
      folderID: originalStrategy.folderID,
      pages: newPages,
      themeProfileId: originalStrategy.themeProfileId,
      themeOverridePalette: originalStrategy.themeOverridePalette,
    );

    await strategyBox.put(duplicatedStrategy.id, duplicatedStrategy);
  }

  Future<void> deleteStrategy(String strategyID) async {
    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).delete(strategyID);

    final directory = await getApplicationSupportDirectory();

    final customDirectory = Directory(path.join(directory.path, strategyID));

    if (!await customDirectory.exists()) return;

    await customDirectory.delete(recursive: true);
  }

  Future<void> saveToHive(String id) async {
    // final drawingData = ref.read(drawingProvider).elements;
    // final agentData = ref.read(agentProvider);
    // final abilityData = ref.read(abilityProvider);
    // final textData = ref.read(textProvider);
    // final mapData = ref.read(mapProvider);
    // final imageData = ref.read(placedImageProvider).images;
    // final utilityData = ref.read(utilityProvider);
    await _syncCurrentPageToHive();

    final StrategyData? savedStrat =
        Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(id);

    if (savedStrat == null) return;

    final strategyTheme = ref.read(strategyThemeProvider);
    final currentStrategy = savedStrat.copyWith(
      mapData: ref.read(mapProvider).currentMap,
      lastEdited: DateTime.now(),
      themeProfileId: strategyTheme.profileId,
      clearThemeProfileId: strategyTheme.profileId == null,
      themeOverridePalette: strategyTheme.overridePalette,
      clearThemeOverridePalette: strategyTheme.overridePalette == null,
    );

    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .put(currentStrategy.id, currentStrategy);

    state = state.copyWith(
      isSaved: true,
    );
    log("Save to hive was called");
  }

  // Flush currently active page (uses activePageID). Safe if null/missing.
  Future<void> _syncCurrentPageToHive() async {
    ref.read(textDraftProvider.notifier).commitAllDrafts();
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    log("Syncing current page to hive for strategy ${state.id}");
    final strat = box.get(state.id);
    if (strat == null || strat.pages.isEmpty) {
      log("No strategy or pages found for syncing.");
      return;
    }

    final pageId = activePageID ?? strat.pages.first.id;
    final idx = strat.pages.indexWhere((p) => p.id == pageId);
    if (idx == -1) {
      log("Active page ID $pageId not found in strategy ${strat.id}");
      return;
    }

    final updatedPage = strat.pages[idx].copyWith(
      drawingData: ref.read(drawingProvider).elements,
      agentData: ref.read(agentProvider),
      abilityData: ref.read(abilityProvider),
      textData: ref.read(textProvider),
      imageData: ref.read(placedImageProvider).images,
      utilityData: ref.read(utilityProvider),
      isAttack: ref.read(mapProvider).isAttack,
      settings: ref.read(strategySettingsProvider),
      lineUps: ref.read(lineUpProvider).lineUps,
    );

    final strategyTheme = ref.read(strategyThemeProvider);
    final newPages = [...strat.pages]..[idx] = updatedPage;
    final updated = strat.copyWith(
      pages: newPages,
      mapData: ref.read(mapProvider).currentMap,
      themeProfileId: strategyTheme.profileId,
      clearThemeProfileId: strategyTheme.profileId == null,
      themeOverridePalette: strategyTheme.overridePalette,
      clearThemeOverridePalette: strategyTheme.overridePalette == null,
      lastEdited: DateTime.now(),
    );
    await box.put(updated.id, updated);
  }

  /// Copies current [strategySettingsProvider] marker sizes to every page in
  /// the open strategy (after flushing the active page to Hive).
  Future<void> applyMarkerSizesToAllPages() async {
    if (state.stratName == null) return;

    await _syncCurrentPageToHive();

    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final strat = box.get(state.id);
    if (strat == null || strat.pages.isEmpty) return;

    final target = ref.read(strategySettingsProvider);
    final newPages = [
      for (final page in strat.pages)
        page.copyWith(
          settings: page.settings.copyWith(
            agentSize: target.agentSize,
            abilitySize: target.abilitySize,
          ),
        ),
    ];

    final strategyTheme = ref.read(strategyThemeProvider);
    final updated = strat.copyWith(
      pages: newPages,
      mapData: ref.read(mapProvider).currentMap,
      themeProfileId: strategyTheme.profileId,
      clearThemeProfileId: strategyTheme.profileId == null,
      themeOverridePalette: strategyTheme.overridePalette,
      clearThemeOverridePalette: strategyTheme.overridePalette == null,
      lastEdited: DateTime.now(),
    );
    await box.put(updated.id, updated);
    setUnsaved();
  }

  void moveToFolder({required String strategyID, required String? parentID}) {
    final strategyBox = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final strategy = strategyBox.get(strategyID);

    if (strategy != null) {
      strategy.folderID = parentID;
      strategy.save();
    } else {
      log("Strategy with ID $strategyID not found.");
    }
  }
}

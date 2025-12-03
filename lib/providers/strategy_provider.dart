import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/transition_provider.dart';
import 'image_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/auto_save_notifier.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/utility_provider.dart';
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
    );
  }
}

class StrategyState {
  StrategyState({
    required this.isSaved,
    required this.stratName,
    required this.id,
    required this.storageDirectory,
  });

  final bool isSaved;
  final String? stratName;
  final String id;
  final String? storageDirectory;

  StrategyState copyWith({
    bool? isSaved,
    String? stratName,
    String? id,
    String? storageDirectory,
  }) {
    return StrategyState(
      isSaved: isSaved ?? this.isSaved,
      stratName: stratName ?? this.stratName,
      id: id ?? this.id,
      storageDirectory: storageDirectory ?? this.storageDirectory,
    );
  }
}

final strategyProvider =
    NotifierProvider<StrategyProvider, StrategyState>(StrategyProvider.new);

class StrategyProvider extends Notifier<StrategyState> {
  String? activePageID;

  @override
  StrategyState build() {
    return StrategyState(
      isSaved: false,
      stratName: null,
      id: "testID",
      storageDirectory: null,
    );
  }

  Timer? _saveTimer;

  bool _saveInProgress = false;
  bool _pendingSave = false;

  //Used For Images
  void setFromState(StrategyState newState) {
    state = newState;
  }

  void setUnsaved() async {
    log("Setting unsaved is being called");

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
        _saveTimer = Timer(const Duration(milliseconds: 500), () {
          _performSave(id);
        });
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

    log(customDirectory.path);
    return customDirectory;
  }

  Future<void> clearCurrentStrategy() async {
    activePageID = null;
    state = StrategyState(
      isSaved: true,
      stratName: null,
      id: "testID",
      storageDirectory: state.storageDirectory,
    );
  }

  // --- MIGRATION: create a first page from legacy flat fields ----------------

  static Future<void> migrateAllStrategies() async {
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    for (final strat in box.values) {
      await migrateLegacyToSinglePage(strat.id);
    }
    log("MIGRATION COMPLETE");
  }

  static Future<void> migrateLegacyToSinglePage(String strategyID) async {
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final strat = box.get(strategyID);
    if (strat == null) return;

    // Already migrated
    if (strat.pages.isNotEmpty) return;
    log("Migrating legacy strategy to single page");
    // Copy ability data & apply legacy adjustment (same logic you had in load)

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

    await box.put(updated.id, updated);
  }

  static Future<StrategyData> migrateLegacyObjectToSinglePage(
      StrategyData strat) async {
    // Already migrated
    if (strat.pages.isNotEmpty) return strat;
    log("Migrating legacy strategy to single page");
    // Copy ability data & apply legacy adjustment (same logic you had in load)

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

    return updated;
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

    ref.read(actionProvider.notifier).clearAllActions();
    ref.read(agentProvider.notifier).fromHive(page.agentData);
    ref.read(abilityProvider.notifier).fromHive(page.abilityData);
    ref.read(drawingProvider.notifier).fromHive(page.drawingData);
    ref.read(textProvider.notifier).fromHive(page.textData);
    ref.read(placedImageProvider.notifier).fromHive(page.imageData);
    ref.read(utilityProvider.notifier).fromHive(page.utilityData);
    ref.read(mapProvider.notifier).setAttack(page.isAttack);
    ref.read(strategySettingsProvider.notifier).fromHive(page.settings);
    ref.read(lineUpProvider.notifier).fromHive(page.lineUps);

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
    await setActivePage(nextPage.id);
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
    await setActivePage(nextPage.id);
  }

// Add these inside StrategyProvider
  Future<void> setActivePageAnimated(String pageID) async {
    final prev = _snapshotAllPlaced();
    ref.read(transitionProvider.notifier).setAllWidgets(prev.values.toList());
    ref.read(transitionProvider.notifier).setHideView(true);

    // Load target page (hydrates providers)
    await setActivePage(pageID);

    // After layout, snapshot next and start transition
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final next = _snapshotAllPlaced();
      final entries = _diffToTransitions(prev, next);
      if (entries.isNotEmpty) {
        ref
            .read(transitionProvider.notifier)
            .start(entries, duration: const Duration(seconds: 1));
      } else {
        ref.read(transitionProvider.notifier).complete();
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

    // Move / appear
    next.forEach((id, to) {
      final from = prev[id];
      if (from != null) {
        if (from.position != to.position ||
            PageTransitionEntry.rotationOf(from) !=
                PageTransitionEntry.rotationOf(to) ||
            PageTransitionEntry.lengthOf(from) !=
                PageTransitionEntry.lengthOf(to)) {
          entries.add(PageTransitionEntry.move(from: from, to: to));
        } else {
          // Unchanged: include as 'none' so it stays visible while base view is hidden
          entries.add(PageTransitionEntry.none(to: to));
        }
      } else {
        entries.add(PageTransitionEntry.appear(to: to));
      }
    });

    // Disappear
    prev.forEach((id, from) {
      if (!next.containsKey(id)) {
        entries.add(PageTransitionEntry.disappear(from: from));
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
      log("Couldn't find save");
      return;
    }
    ref.read(actionProvider.notifier).clearAllActions();

    // List<PlacedImage> pageImageData = [];
    // for (final page in newStrat.pages) {
    //   pageImageData.addAll(page.imageData);
    // }
    // await ref
    //     .read(placedImageProvider.notifier)
    //     .deleteUnusedImages(newStrat.id, pageImageData);

    final firstPage = newStrat.pages.first;

    // We clear previous data to avoid artifacts when loading a new strategy
    log(firstPage.toString());
    ref.read(agentProvider.notifier).fromHive(firstPage.agentData);
    ref.read(abilityProvider.notifier).fromHive(firstPage.abilityData);
    ref.read(drawingProvider.notifier).fromHive(firstPage.drawingData);
    ref
        .read(mapProvider.notifier)
        .fromHive(newStrat.mapData, newStrat.pages.first.isAttack);
    ref.read(textProvider.notifier).fromHive(firstPage.textData);
    ref.read(placedImageProvider.notifier).fromHive(firstPage.imageData);
    ref.read(lineUpProvider.notifier).fromHive(firstPage.lineUps);
    ref.read(strategySettingsProvider.notifier).fromHive(firstPage.settings);
    ref.read(utilityProvider.notifier).fromHive(firstPage.utilityData);
    activePageID = firstPage.id;

    if (kIsWeb) {
      state = StrategyState(
        isSaved: true,
        stratName: newStrat.name,
        id: newStrat.id,
        storageDirectory: null,
      );
      return;
    }
    final newDir = await setStorageDirectory(newStrat.id);

    state = StrategyState(
      isSaved: true,
      stratName: newStrat.name,
      id: newStrat.id,
      storageDirectory: newDir.path,
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
      await _loadFromXFile(file.xFile);
    }
  }

  Future<void> loadFromFileDrop(List<XFile> files) async {
    for (XFile file in files) {
      await _loadFromXFile(file);
    }
  }

  Future<Directory> getTempDirectory(String strategyID) async {
    final tempDirectory = await getTemporaryDirectory();

    Directory tempDir = await Directory(
            path.join(tempDirectory.path, "xyz.icarus-strats", strategyID))
        .create(recursive: true);
    return tempDir;
  }

  Future<void> cleanUpTempDirectory(String strategyID) async {
    final tempDirectory = await getTempDirectory(strategyID);
    await tempDirectory.delete(recursive: true);
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

  Future<void> _loadFromXFile(XFile xFile) async {
    final newID = const Uuid().v4();

    bool isZip = await isZipFile(File(xFile.path));

    log("Is ZIP file: $isZip");
    final bytes = await xFile.readAsBytes();
    String jsonData = "";
    if (isZip) {
      // Decode the Zip file
      final archive = ZipDecoder().decodeBytes(bytes);

      final imageFolder = await PlacedImageProvider.getImageFolder(newID);

      final tempDirectory = await getTempDirectory(newID);

      await extractArchiveToDisk(archive, tempDirectory.path);

      final tempDirectoryList = tempDirectory.listSync();

      try {
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
      } catch (e) {
        log(e.toString());
        return;
      }
    } else {
      jsonData = await xFile.readAsString();
    }

    Map<String, dynamic> json = jsonDecode(jsonData);

    final List<DrawingElement> drawingData =
        DrawingProvider.fromJson(jsonEncode(json["drawingData"] ?? []));
    List<PlacedAgent> agentData =
        AgentProvider.fromJson(jsonEncode(json["agentData"] ?? []));

    final List<PlacedAbility> abilityData =
        AbilityProvider.fromJson(jsonEncode(json["abilityData"] ?? []));

    final mapData = MapProvider.fromJson(jsonEncode(json["mapData"]));
    final textData = TextProvider.fromJson(jsonEncode(json["textData"] ?? []));

    List<PlacedImage> imageData = [];
    if (!kIsWeb) {
      if (isZip) {
        imageData = await PlacedImageProvider.fromJson(
            jsonString: jsonEncode(json["imageData"] ?? []), strategyID: newID);
      } else {
        log('Legacy image data loading');
        imageData = await PlacedImageProvider.legacyFromJson(
            jsonString: jsonEncode(json["imageData"] ?? []), strategyID: newID);
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

    final versionNumber = int.tryParse(json["versionNumber"].toString()) ??
        Settings.versionNumber;

    bool needsMigration = (versionNumber < 15);
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
      name: path.basenameWithoutExtension(xFile.name),
      mapData: mapData,
      versionNumber: versionNumber,
      lastEdited: DateTime.now(),

      folderID: null,
    );
    if (needsMigration) {
      newStrategy = await migrateLegacyObjectToSinglePage(newStrategy);
    }
    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .put(newStrategy.id, newStrategy);

    await cleanUpTempDirectory(newStrategy.id);
  }

  Future<String> createNewStrategy(String name) async {
    final newID = const Uuid().v4();
    final pageID = const Uuid().v4();
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
    );

    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .put(newStrategy.id, newStrategy);

    return newStrategy.id;
  }

  //Get all of the stratgies in the folder
  // Stop if there's nothing there
  // Call export and get the individual files
  // and then we put them all into one massive zip file

  Future<void> exportFolder(String folderID) async {
    final folder = Hive.box<Folder>(HiveBoxNames.foldersBox).get(folderID);
    if (folder == null) {
      log("Couldn't find folder to export");
      return;
    }

    final directoryToZip =
        await Directory.systemTemp.createTemp('strategy_export');

    try {
      await zipFolder(directoryToZip, folderID);

      final outputFile = await FilePicker.platform.saveFile(
        type: FileType.custom,
        dialogTitle: 'Please select an output file:',
        fileName: "${sanitizeFileName(folder.name)}.zip",
        allowedExtensions: ['zip'], // no leading dot
      );

      if (outputFile == null) return;

      final encoder = ZipFileEncoder();
      encoder.create(outputFile);
      await encoder.addDirectory(directoryToZip, includeDirName: false);
      await encoder.close();
    } finally {
      // Best-effort cleanup
      try {
        await directoryToZip.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> zipFolder(Directory directoryToZip, String folderID) async {
    final Folder? currentFolder =
        ref.read(folderProvider.notifier).findFolderByID(folderID);
    if (currentFolder == null) return;
    final strategies = Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .values
        .where((strategy) => strategy.folderID == folderID)
        .toList();

    final subFolders =
        ref.read(folderProvider.notifier).findFolderChildren(folderID);
    final sanitizedName = sanitizeFileName(currentFolder.name);
    Directory folderExportDirectory =
        Directory(path.join(directoryToZip.path, sanitizedName));
    int counter = 1;
    while (await folderExportDirectory.exists()) {
      folderExportDirectory = Directory(
          path.join(directoryToZip.path, "${sanitizedName}_$counter"));
      counter++;
    }

    // Create the folder
    await folderExportDirectory.create(recursive: true);

    // Export each strategy
    for (final strategy in strategies) {
      await zipStrategy(id: strategy.id, saveDir: folderExportDirectory);
    }

    for (final subFolder in subFolders) {
      await zipFolder(folderExportDirectory, subFolder.id);
    }
  }

  static String sanitizeFileName(String input) {
    final sanitized = input.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    return sanitized.isEmpty ? 'untitled' : sanitized;
  }

  Future<void> zipStrategy({
    required String id,
    Directory? saveDir, // used when outputFilePath is not provided
    String? outputFilePath, // exact .ica path from FilePicker
  }) async {
    final strategy = Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(id);
    if (strategy == null) {
      log("Couldn't find strategy to export");
      return;
    }

    final pages = strategy.pages.map((p) => p.toJson(strategy.id)).toList();
    final pageJson = jsonEncode(pages);
    final data = '''
                  {
                  "versionNumber": "${Settings.versionNumber}",
                  "mapData": ${ref.read(mapProvider.notifier).toJson()},
                  "settingsData":${ref.read(strategySettingsProvider.notifier).toJson()},
                  "isAttack": "${ref.read(mapProvider).isAttack.toString()}",
                  "pages": $pageJson
                  }
                ''';

    final sanitizedStrategyName = sanitizeFileName(strategy.name);

    // Resolve output path and base name
    late final String outPath;
    late final String archiveBase;
    if (outputFilePath != null) {
      outPath = outputFilePath;
      archiveBase = path.basenameWithoutExtension(outPath);
    } else {
      final base = sanitizedStrategyName;
      var candidate = base;
      var n = 1;
      while (File(path.join(saveDir!.path, "$candidate.ica")).existsSync()) {
        candidate = "${base}_$n";
        n++;
      }
      archiveBase = candidate;
      outPath = path.join(saveDir.path, "$archiveBase.ica");
    }

    final jsonArchiveFile =
        ArchiveFile.bytes("$archiveBase.json", utf8.encode(data));

    final zipEncoder = ZipFileEncoder()..create(outPath);

    final supportDirectory = await getApplicationSupportDirectory();
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
  }

  Future<void> exportFile(String id) async {
    await forceSaveNow(id);

    final outputFile = await FilePicker.platform.saveFile(
      type: FileType.custom,
      dialogTitle: 'Please select an output file:',
      fileName: "${state.stratName ?? "new strategy"}.ica",
      allowedExtensions: [".ica"],
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

    final currentStrategy = savedStrat.copyWith(
      mapData: ref.read(mapProvider).currentMap,
      lastEdited: DateTime.now(),
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

    final newPages = [...strat.pages]..[idx] = updatedPage;
    final updated = strat.copyWith(pages: newPages, lastEdited: DateTime.now());
    await box.put(updated.id, updated);
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

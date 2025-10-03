import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'package:cross_file/cross_file.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/auto_save_notifier.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/image_provider.dart';
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
  final List<DrawingElement> drawingData;
  final List<PlacedAgent> agentData;
  final List<PlacedAbility> abilityData;
  final List<PlacedText> textData;
  final List<PlacedImage> imageData;
  final List<PlacedUtility> utilityData;
  final List<StrategyPage> pages;
  final MapValue mapData;
  final DateTime lastEdited;
  final bool isAttack;
  final StrategySettings strategySettings;

  String? folderID;

  StrategyData({
    this.isAttack = true,
    required this.id,
    required this.name,
    required this.drawingData,
    required this.agentData,
    required this.abilityData,
    required this.textData,
    required this.imageData,
    required this.mapData,
    required this.versionNumber,
    required this.lastEdited,
    required this.folderID,
    this.utilityData = const [],
    this.pages = const [],
    StrategySettings? strategySettings,
  }) : strategySettings = strategySettings ?? StrategySettings();

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
  }) {
    return StrategyData(
      id: id ?? this.id,
      name: name ?? this.name,
      versionNumber: versionNumber ?? this.versionNumber,
      drawingData: drawingData ?? this.drawingData,
      agentData: agentData ?? this.agentData,
      abilityData: abilityData ?? this.abilityData,
      textData: textData ?? this.textData,
      imageData: imageData ?? this.imageData,
      utilityData: utilityData ?? this.utilityData,
      pages: pages ?? this.pages,
      mapData: mapData ?? this.mapData,
      lastEdited: lastEdited ?? this.lastEdited,
      isAttack: isAttack ?? this.isAttack,
      strategySettings: strategySettings ?? this.strategySettings,
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
      ref.read(autoSaveProvider.notifier).ping();
      await saveToHive(state.id);
    });
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
    state = StrategyState(
      isSaved: true,
      stratName: null,
      id: "testID",
      storageDirectory: state.storageDirectory,
    );
  }

  Future<void> setActivePage(String pageID) async {
    activePageID = pageID;

    final doc =
        Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(state.id);
    if (doc == null) return;
    final page = doc.pages.firstWhere((page) => page.id == pageID);

    ref.read(actionProvider.notifier).clearAllActions();

    // Hydrate all area providers with page data
    ref.read(agentProvider.notifier).fromHive(page.agentData);
    ref.read(abilityProvider.notifier).fromHive(page.abilityData);
    ref.read(drawingProvider.notifier).fromHive(page.drawingData);
    ref.read(textProvider.notifier).fromHive(page.textData);
    ref.read(placedImageProvider.notifier).fromHive(page.imageData);
    ref.read(utilityProvider.notifier).fromHive(page.utilityData);
  }

  Future<void> addPage({required String name}) async {
    final box =
        Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(state.id);
    if (box == null) {
      throw Exception("No strategy found with ID ${state.id}");
    }

    final newPage = StrategyPage(
      id: const Uuid().v4(),
      name: name,
      drawingData: [],
      agentData: [],
      abilityData: [],
      textData: [],
      imageData: [],
      utilityData: [],
      sortIndex: box.pages.isNotEmpty ? box.pages.length - 1 : 0,
    );

    final updatedPages = [...box.pages, newPage];
    final updatedStrategy = box.copyWith(pages: updatedPages);

    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .put(updatedStrategy.id, updatedStrategy);

    // return box.put(newPage.id, newPage);
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
    await ref
        .read(placedImageProvider.notifier)
        .deleteUnusedImages(newStrat.id, newStrat.imageData);

    ref.read(agentProvider.notifier).fromHive(newStrat.agentData);

    final List<PlacedAbility> updatedAbility = [...newStrat.abilityData];
    if (newStrat.versionNumber < 7) {
      log("Updating ability positions for version < 7");
      for (PlacedAbility ability in updatedAbility) {
        if (ability.data.abilityData! is SquareAbility) {
          ability.position = ability.position.translate(0, -7.5);
        }
      }
    }

    ref.read(abilityProvider.notifier).fromHive(updatedAbility);
    ref.read(drawingProvider.notifier).fromHive(newStrat.drawingData);
    ref
        .read(mapProvider.notifier)
        .fromHive(newStrat.mapData, newStrat.isAttack);
    ref.read(textProvider.notifier).fromHive(newStrat.textData);
    ref.read(placedImageProvider.notifier).fromHive(newStrat.imageData);

    ref
        .read(strategySettingsProvider.notifier)
        .fromHive(newStrat.strategySettings);
    ref.read(utilityProvider.notifier).fromHive(newStrat.utilityData);

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

  Future<void> _loadFromXFile(XFile file) async {
    if (path.extension(file.path) != ".ica") return;

    final data = await file.readAsString();

    Map<String, dynamic> json = jsonDecode(data);

    final newID = const Uuid().v4();

    final List<DrawingElement> drawingData = ref
        .read(drawingProvider.notifier)
        .fromJson(jsonEncode(json["drawingData"]));
    List<PlacedAgent> agentData = ref
        .read(agentProvider.notifier)
        .fromJson(jsonEncode(json["agentData"]));

    final List<PlacedAbility> abilityData = ref
        .read(abilityProvider.notifier)
        .fromJson(jsonEncode(json["abilityData"]));

    final mapData =
        ref.read(mapProvider.notifier).fromJson(jsonEncode(json["mapData"]));
    final textData =
        ref.read(textProvider.notifier).fromJson(jsonEncode(json["textData"]));

    final imageData = await ref.read(placedImageProvider.notifier).fromJson(
        jsonString: jsonEncode(json["imageData"] ?? []), strategyID: newID);

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
      utilityData = ref
          .read(utilityProvider.notifier)
          .fromJson(jsonEncode(json["utilityData"]));
    } else {
      utilityData = [];
    }

    final versionNumber = int.tryParse(json["versionNumber"].toString()) ??
        Settings.versionNumber;
    final newStrategy = StrategyData(
        id: newID,
        name: path.basenameWithoutExtension(file.name),
        drawingData: drawingData,
        agentData: agentData,
        abilityData: abilityData,
        textData: textData,
        imageData: imageData,
        mapData: mapData,
        versionNumber: versionNumber,
        lastEdited: DateTime.now(),
        isAttack: isAttack,
        strategySettings: settingsData,
        utilityData: utilityData,
        folderID: null);

    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .put(newStrategy.id, newStrategy);
  }

  Future<String> createNewStrategy(String name) async {
    final newID = const Uuid().v4();
    final newStrategy = StrategyData(
      drawingData: [],
      agentData: [],
      abilityData: [],
      textData: [],
      imageData: [],
      utilityData: [],
      mapData: MapValue.ascent,
      versionNumber: Settings.versionNumber,
      id: newID,
      name: name,
      lastEdited: DateTime.now(),
      strategySettings: StrategySettings(),
      folderID: ref.read(folderProvider),
    );

    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .put(newStrategy.id, newStrategy);

    return newStrategy.id;
  }

  Future<void> exportFile(String id) async {
    await saveToHive(id);
    String fetchedImageData =
        await ref.read(placedImageProvider.notifier).toJson(id);
    // Json has no trailing commas
    String data = '''
                {
                "versionNumber": "${Settings.versionNumber}",
                "drawingData": ${ref.read(drawingProvider.notifier).toJson()},
                "agentData": ${ref.read(agentProvider.notifier).toJson()},
                "abilityData": ${ref.read(abilityProvider.notifier).toJson()},
                "textData": ${ref.read(textProvider.notifier).toJson()},
                "mapData": ${ref.read(mapProvider.notifier).toJson()},
                "imageData":$fetchedImageData,
                "settingsData":${ref.read(strategySettingsProvider.notifier).toJson()},
                "isAttack": "${ref.read(mapProvider).isAttack.toString()}",
                "utilityData": ${ref.read(utilityProvider.notifier).toJson()}
                }
              ''';

    File file;
    // log("File name: ${state.fileName}");

    String? outputFile = await FilePicker.platform.saveFile(
      type: FileType.custom,
      dialogTitle: 'Please select an output file:',
      fileName: "${state.stratName ?? "new strategy"}.ica",
      allowedExtensions: [".ica"],
    );

    if (outputFile == null) return;
    file = File(outputFile);

    file.writeAsStringSync(data);
    // state = state.copyWith(fileName: file.path, isSaved: true);
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

  Future<void> deleteStrategy(String strategyID) async {
    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).delete(strategyID);

    final directory = await getApplicationSupportDirectory();

    final customDirectory = Directory(path.join(directory.path, strategyID));

    if (!await customDirectory.exists()) return;

    await customDirectory.delete(recursive: true);
  }

  Future<void> saveToHive(String id) async {
    final drawingData = ref.read(drawingProvider).elements;
    final agentData = ref.read(agentProvider);
    final abilityData = ref.read(abilityProvider);
    final textData = ref.read(textProvider);
    final mapData = ref.read(mapProvider);
    final imageData = ref.read(placedImageProvider).images;
    final strategySettings = ref.read(strategySettingsProvider);
    final utilityData = ref.read(utilityProvider);

    final StrategyData? savedStrat =
        Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(id);

    final currentStategy = StrategyData(
      drawingData: drawingData,
      agentData: agentData,
      abilityData: abilityData,
      textData: textData,
      imageData: imageData,
      mapData: mapData.currentMap,
      isAttack: mapData.isAttack,
      utilityData: utilityData,
      versionNumber: Settings.versionNumber,
      id: id,
      name: state.stratName ?? "placeholder",
      lastEdited: DateTime.now(),
      strategySettings: strategySettings,
      folderID: savedStrat?.folderID,
    );

    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .put(currentStategy.id, currentStategy);
    state = state.copyWith(
      isSaved: true,
    );
    log("Save to hive was called");
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

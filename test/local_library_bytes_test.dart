import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/migrations/hidden_folder_repair.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'opens_now_support.dart';

const _recordedAt = 'eea7b52d';
const _fixture = 'test/fixtures/local_library_bytes/session_at_$_recordedAt.json';
const _boxes = [HiveBoxNames.strategiesBox, HiveBoxNames.foldersBox];
final _uuid = RegExp(
  '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}',
);

final class _FixedTimeAdapter extends TypeAdapter<DateTime> {
  @override
  final typeId = 18;

  @override
  DateTime read(BinaryReader reader) {
    final millis = reader.readInt();
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: reader.readBool());
  }

  @override
  void write(BinaryWriter writer, DateTime obj) {
    writer.writeInt(0);
    writer.writeBool(obj.isUtc);
  }
}

List<Uint8List> _frames(Uint8List file) {
  final data = ByteData.sublistView(file);
  final frames = <Uint8List>[];
  for (var offset = 0; offset < file.length;) {
    final length = data.getUint32(offset, Endian.little);
    frames.add(file.sublist(offset + 4, offset + length - 4));
    offset += length;
  }
  return frames;
}

final class _Recording {
  final steps = <Map<String, Object>>[];
  final _ids = <String, String>{};
  late final String dir;

  List<Uint8List> framesOf(String box) {
    final file = File('$dir/$box.hive');
    return file.existsSync() ? _frames(file.readAsBytesSync()) : const [];
  }

  void step(String name) => steps.add({
        'step': name,
        for (final box in _boxes) box: framesOf(box).length,
      });

  String _normalized(Uint8List frame) => base64.encode(
        latin1.encode(
          latin1.decode(frame).replaceAllMapped(
                _uuid,
                (match) => _ids.putIfAbsent(
                  match[0]!,
                  () => '00000000-0000-4000-8000-'
                      '${_ids.length.toString().padLeft(12, '0')}',
                ),
              ),
        ),
      );

  Map<String, Object> toJson() => {
        'recordedAt': _recordedAt,
        'steps': steps,
        for (final box in _boxes)
          box: [for (final frame in framesOf(box)) _normalized(frame)],
      };
}

StrategyPage _page(String id, int index) => StrategyPage(
      id: id,
      name: 'Page ${index + 1}',
      isAutoNamed: true,
      drawingData: const [],
      agentData: [
        PlacedAgent(
          id: '$id-agent',
          type: AgentType.sova,
          position: Offset(10.0 * (index + 1), 20),
        ),
      ],
      abilityData: const [],
      textData: const [],
      imageData: const [],
      utilityData: const [],
      sortIndex: index,
      isAttack: true,
      settings: StrategySettings(),
    );

StrategyData _legacy(String id, {String? folderId}) => StrategyData(
      id: id,
      name: 'Legacy $id',
      mapData: MapValue.bind,
      versionNumber: 1,
      lastEdited: DateTime.utc(2025, 3, 4),
      createdAt: DateTime.utc(2025, 3, 1),
      folderID: folderId,
      pages: [_page('$id-p1', 0), _page('$id-p2', 1)],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an editing session leaves the Hive bytes it left at $_recordedAt',
      () async {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
    final tempDir = await Directory.systemTemp.createTemp('icarus-bytes-');
    addTearDown(() => tempDir.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
    Hive.init(tempDir.path);
    registerIcarusAdapters(Hive);
    Hive.registerAdapter(_FixedTimeAdapter(), internal: true, override: true);
    final strategies =
        await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    final folders = await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
    await Hive.openBox<int>(HiveBoxNames.pinnedItemsBox);
    addTearDown(Hive.close);

    final recording = _Recording()..dir = tempDir.path;
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(strategyProvider.notifier);
    final library = container.read(folderProvider.notifier);
    await container
        .read(appPreferencesProvider.notifier)
        .setAutosaveEnabled(false);

    await strategies.put('library-legacy', _legacy('library-legacy'));
    await StrategyMigrator.migrateAllStrategies();
    recording.step('migrate the library at startup');

    final plans = await library.createFolder(
      name: 'Plans',
      iconId: 1,
      color: FolderColor.blue,
    );
    recording.step('create a folder');

    final created = await notifier.createNewStrategy(
      map: MapValue.ascent,
      name: 'Session',
      local: true,
    );
    recording.step('create a strategy');

    await notifier.moveToFolder(strategyID: created.id, parentID: plans.id);
    recording.step('move the strategy into the folder');

    await notifier.loadFromHive(created.id);
    recording.step('open the strategy');

    container.read(agentProvider.notifier).addAgent(
          PlacedAgent(
            id: 'jett-1',
            type: AgentType.jett,
            position: const Offset(300, 200),
          ),
        );
    container
        .read(textProvider.notifier)
        .addText(PlacedText(id: 'note-1', position: const Offset(50, 60)));
    container.read(strategySaveStateProvider.notifier).markDirty();
    await notifier.forceSaveNow(created.id);
    recording.step('save edits on the first page');

    await notifier.addPage();
    recording.step('add a page');

    final secondPageId =
        container.read(strategyPageSessionProvider).activePageId!;
    await notifier.renamePage(secondPageId, 'Retake');
    recording.step('rename the page');

    container.read(agentProvider.notifier).addAgent(
          PlacedAgent(
            id: 'omen-1',
            type: AgentType.omen,
            position: const Offset(500, 400),
          ),
        );
    await notifier.copyPlacedWidgetToAdjacentPage(
      widgetId: 'omen-1',
      direction: PageTransitionDirection.backward,
    );
    recording.step('copy an agent to the page before');

    await notifier.reorderPage(1, 0);
    recording.step('reorder the pages');

    await notifier.switchSide(allPages: true);
    recording.step('switch side on every page');

    await notifier.applyMarkerSizesToAllPages();
    recording.step('apply marker sizes to every page');

    await notifier.addPage('Exec');
    final thirdPageId =
        container.read(strategyPageSessionProvider).activePageId!;
    await notifier.deletePage(thirdPageId);
    recording.step('add and delete a page');

    await notifier.renameStrategy(created.id, 'Session renamed');
    recording.step('rename the strategy');

    await notifier.duplicateStrategy(created.id);
    final copy = strategies.values.firstWhere(
      (strategy) => strategy.name == 'Session renamed (Copy)',
    );
    recording.step('duplicate the strategy');

    await notifier.deleteStrategy(copy.id);
    recording.step('delete the copy');

    await library.editFolder(
      folder: folders.get(plans.id)!,
      newName: 'Plans A',
      newIconId: 2,
      newColor: FolderColor.custom,
      newCustomColor: const Color(0xFF336699),
    );
    recording.step('restyle the folder');

    final archive = await library.createFolder(
      name: 'Archive',
      iconId: 3,
      color: FolderColor.green,
    );
    await library.moveToFolder(folderID: plans.id, parentID: archive.id);
    recording.step('move the folder into another');

    await folders.put(
      'orphan-folder',
      Folder(
        name: 'Orphan',
        id: 'orphan-folder',
        dateCreated: DateTime.utc(2025, 5, 6),
        parentID: 'gone-folder',
      ),
    );
    await strategies.put(
      'orphan-strategy',
      _legacy('orphan-strategy', folderId: 'gone-folder'),
    );
    await moveOrphansToTopLevel();
    recording.step('move orphans to the top level');

    await strategies.put('opened-legacy', _legacy('opened-legacy'));
    await notifier.loadFromHive('opened-legacy');
    recording.step('open a strategy saved by an older build');

    await library.deleteFolder(archive.id);
    recording.step('delete a folder with a strategy inside');

    final session = recording.toJson();
    if (Platform.environment['RECORD_LOCAL_LIBRARY_BYTES'] == '1') {
      File(_fixture)
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(session)}\n',
        );
      return;
    }
    final recorded = jsonDecode(File(_fixture).readAsStringSync());
    expect(session['steps'], recorded['steps']);
    for (final box in _boxes) {
      final frames = session[box]! as List;
      final expected = recorded[box] as List;
      for (var i = 0; i < frames.length && i < expected.length; i++) {
        expect(frames[i], expected[i], reason: '$box frame $i');
      }
      expect(frames.length, expected.length, reason: '$box frames');
    }
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:hive_ce/src/binary/binary_reader_impl.dart';
import 'package:hive_ce/src/binary/binary_writer_impl.dart';
import 'package:hive_ce/src/hive_impl.dart';
import 'package:hive_ce/src/util/logger.dart';
import 'package:icarus/collab/field_merge.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/strategy/strategy_migrator.dart';

const _door = 'summit-mid';

class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

PlacedUtility _bar(String id, {String? mapDoor}) => PlacedUtility(
      id: id,
      type: UtilityType.customRectangle,
      position: const Offset(30, 40),
      customWidth: 2,
      customLength: 12,
      customColorValue: 0xFF000000,
      customOpacityPercent: 100,
      mapDoor: mapDoor,
    );

/// The utility adapter desktop 5.1.3 shipped with, from before captions: it
/// knows every field to 15 and reads past the rest.
class _Shipped513PlacedUtilityAdapter extends TypeAdapter<PlacedUtility> {
  @override
  final typeId = 15;

  @override
  PlacedUtility read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return PlacedUtility(
      type: fields[0] as UtilityType,
      position: fields[5] as Offset,
      id: fields[3] as String,
      isAlly: fields[14] == null ? true : fields[14] as bool,
      angle: fields[6] == null ? 0.0 : (fields[6] as num).toDouble(),
      visionElevation: (fields[15] as num?)?.toDouble(),
      customDiameter: (fields[8] as num?)?.toDouble(),
      customWidth: (fields[9] as num?)?.toDouble(),
      customLength: (fields[10] as num?)?.toDouble(),
      customColorValue: (fields[11] as num?)?.toInt(),
      customOpacityPercent: (fields[12] as num?)?.toInt(),
    )
      ..rotation = (fields[1] as num).toDouble()
      ..length = (fields[2] as num).toDouble()
      ..isDeleted = fields[4] as bool;
  }

  @override
  void write(BinaryWriter writer, PlacedUtility obj) {
    writer
      ..writeByte(14)
      ..writeByte(0)
      ..write(obj.type)
      ..writeByte(1)
      ..write(obj.rotation)
      ..writeByte(2)
      ..write(obj.length)
      ..writeByte(3)
      ..write(obj.id)
      ..writeByte(4)
      ..write(obj.isDeleted)
      ..writeByte(5)
      ..write(obj.position)
      ..writeByte(6)
      ..write(obj.angle)
      ..writeByte(8)
      ..write(obj.customDiameter)
      ..writeByte(9)
      ..write(obj.customWidth)
      ..writeByte(10)
      ..write(obj.customLength)
      ..writeByte(11)
      ..write(obj.customColorValue)
      ..writeByte(12)
      ..write(obj.customOpacityPercent)
      ..writeByte(14)
      ..write(obj.isAlly)
      ..writeByte(15)
      ..write(obj.visionElevation);
  }
}

HiveImpl _registry() {
  final registry = HiveImpl();
  registerIcarusAdapters(registry);
  return registry;
}

HiveImpl _shipped513Registry() {
  final previous = Logger.level;
  Logger.level = LoggerLevel.error;
  try {
    return _registry()
      ..registerAdapter(_Shipped513PlacedUtilityAdapter(), override: true);
  } finally {
    Logger.level = previous;
  }
}

Uint8List _bytes(HiveImpl registry, Object value) =>
    Uint8List.fromList((BinaryWriterImpl(registry)..write(value)).toBytes());

T _across<T extends Object>(HiveImpl from, HiveImpl to, T value) =>
    BinaryReaderImpl(_bytes(from, value), to).read() as T;

Map<String, Object?> _payload(PlacedUtility item) => {
      'kind': 'utility',
      'payloadVersion': 1,
      'data': jsonDecode(jsonEncode(item.toJson())),
    };

/// One rectangle marking a door and one ordinary rectangle.
StrategyData _strategy() => StrategyData(
      id: 'door-strategy',
      name: 'Doors',
      mapData: MapValue.ascent,
      versionNumber: Settings.versionNumber,
      lastEdited: DateTime.utc(2026, 11, 1),
      folderID: null,
      pages: [
        StrategyPage(
          id: 'page',
          name: 'Page 1',
          sortIndex: 0,
          isAttack: true,
          drawingData: const [],
          agentData: const [],
          abilityData: const [],
          textData: const [],
          imageData: const [],
          utilityData: [_bar('door', mapDoor: _door), _bar('plain')],
          settings: StrategySettings(),
        ),
      ],
    );

void _expectDoors(StrategyData strategy) {
  final utilities = strategy.pages.single.utilityData;
  expect(utilities, hasLength(2));
  expect(utilities.singleWhere((u) => u.mapDoor != null).mapDoor, _door);
  expect(utilities.where((u) => u.mapDoor == null), hasLength(1));
  for (final utility in utilities) {
    expect(utility.position, const Offset(30, 40));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerIcarusAdapters(Hive);
    appProviderContainer = ProviderContainer();
  });
  tearDownAll(() => appProviderContainer.dispose());
  setUp(() => CoordinateSystem(playAreaSize: const Size(1920, 1080)));

  group('a rectangle marking a door', () {
    test('keeps it through its JSON, as a cloud payload carries it', () {
      final item = _bar('a', mapDoor: _door);
      final json = jsonDecode(jsonEncode(item.toJson()));

      expect(json['mapDoor'], _door);
      expect(PlacedUtility.fromJson(json).mapDoor, _door);
    });

    test('keeps it through Hive', () {
      final registry = _registry();

      expect(
        _across(registry, registry, _bar('a', mapDoor: _door)).mapDoor,
        _door,
      );
    });

    test('keeps it beside a caption in Hive', () {
      final registry = _registry();
      final opened = _across(
        registry,
        registry,
        _bar('a', mapDoor: _door)..caption = 'Drop on the plant',
      );

      expect(opened.mapDoor, _door);
      expect(opened.caption, 'Drop on the plant');
    });

    test('keeps it through every copy of a row', () {
      final item = _bar('a', mapDoor: _door);

      expect(item.copyWith(position: const Offset(1, 1)).mapDoor, _door);
      expect(clonePlacedUtility(item).mapDoor, _door);
      expect(item.deepCopy<PlacedUtility>().mapDoor, _door);
    });

    test('keeps it through the migration that rebuilds each row', () {
      final migrated = StrategyMigrator.migrateToWorld16x9(
        _strategy(),
        force: true,
      );

      expect(
        migrated.pages.single.utilityData.map((u) => u.mapDoor),
        [_door, null],
      );
    });
  });

  group('a rectangle that never marked a door', () {
    test('has no key in its JSON, so its payload is unchanged', () {
      expect(_bar('a').toJson().containsKey('mapDoor'), isFalse);
    });

    test('opens with none from a payload written before doors', () {
      final opened = PlacedUtility.fromJson(const {
        'id': 'a',
        'type': 'customRectangle',
        'position': {'dx': 30.0, 'dy': 40.0},
        'rotation': 0.0,
        'length': 0.0,
      });

      expect(opened.mapDoor, isNull);
      expect(opened.type, UtilityType.customRectangle);
    });

    test('saved by desktop 5.1.3, opens with none', () {
      final opened = _across(_shipped513Registry(), _registry(), _bar('a'));

      expect(opened.mapDoor, isNull);
      expect(opened.position, const Offset(30, 40));
      expect(opened.customLength, 12);
    });
  });

  group('an older build', () {
    test('opens a door as the rectangle it is', () {
      final opened = _across(
        _registry(),
        _shipped513Registry(),
        _bar('a', mapDoor: _door)..caption = 'Drop on the plant',
      );

      expect(opened.id, 'a');
      expect(opened.type, UtilityType.customRectangle);
      expect(opened.position, const Offset(30, 40));
      expect(opened.customWidth, 2);
      expect(opened.customLength, 12);
      expect(opened.customColorValue, 0xFF000000);
    });

    // The cost of a rollback that the design accepts: the page's next save by
    // the old build drops the door and keeps the rectangle.
    test('saving it keeps the rectangle and loses the door', () {
      final shipped = _shipped513Registry();
      final current = _registry();

      final opened = _across(current, shipped, _bar('a', mapDoor: _door));
      final reopened = _across(shipped, current, opened);

      expect(reopened.position, const Offset(30, 40));
      expect(reopened.customLength, 12);
      expect(reopened.mapDoor, isNull);
    });
  });

  test('moving a door in the cloud leaves the door out of the merge', () {
    expect(
      elementMergeFields(
        _payload(_bar('a', mapDoor: _door)),
        _payload(
          _bar('a', mapDoor: _door).copyWith(position: const Offset(300, 400)),
        ),
      ),
      ['customLength', 'customWidth', 'position', 'rotation'],
    );
  });

  test('Hive reopen, a real .ica and a library backup round-trip it', () async {
    final directory = await Directory.systemTemp.createTemp('icarus-door-');
    Hive.init(directory.path);
    final container = ProviderContainer(
      overrides: [authProvider.overrideWith(_SignedOut.new)],
    );
    addTearDown(() async {
      container.dispose();
      await Hive.close();
      await directory.delete(recursive: true);
    });
    var box = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
    await MapThemeProfilesProvider.bootstrap();
    await box.put('door-strategy', _strategy());
    await box.close();
    box = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    _expectDoors(box.get('door-strategy')!);

    final service = StrategyImportExportService(container);
    final exported = await service.zipStrategy(
      id: 'door-strategy',
      saveDir: directory,
    );
    final result = await service.loadFromFileDrop([XFile(exported)]);

    expect(result.issues, isEmpty);
    expect(result.strategiesImported, 1);
    expect(box.length, 2);
    box.values.forEach(_expectDoors);

    final backup = await service.buildLibraryExportDirectoryForTest();
    addTearDown(() => backup.delete(recursive: true));
    final backupFile = '${directory.path}/library.zip';
    final encoder = ZipFileEncoder()..create(backupFile);
    await encoder.addDirectory(backup, includeDirName: false);
    await encoder.close();
    final imported = await service.loadFromFileDrop([XFile(backupFile)]);

    expect(imported.issues, isEmpty);
    expect(imported.strategiesImported, 2);
    expect(box.length, 4);
    box.values.forEach(_expectDoors);
  });
}

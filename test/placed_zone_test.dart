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

class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

PlacedUtility _shape(String id, {bool isZone = false}) => PlacedUtility(
      id: id,
      type: UtilityType.customRectangle,
      position: const Offset(30, 40),
      customWidth: 6,
      customLength: 18,
      customColorValue: 0xFF22C55E,
      customOpacityPercent: 30,
      isZone: isZone,
    );

/// The utility adapter desktop 5.2.0 shipped with, from before zones were
/// their own shape: it knows every field to 17 and reads past the rest.
class _Shipped520PlacedUtilityAdapter extends TypeAdapter<PlacedUtility> {
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
      mapDoor: fields[17] as String?,
    )
      ..rotation = (fields[1] as num).toDouble()
      ..length = (fields[2] as num).toDouble()
      ..isDeleted = fields[4] as bool
      ..caption = fields[16] as String?;
  }

  @override
  void write(BinaryWriter writer, PlacedUtility obj) {
    writer
      ..writeByte(16)
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
      ..write(obj.visionElevation)
      ..writeByte(16)
      ..write(obj.caption)
      ..writeByte(17)
      ..write(obj.mapDoor);
  }
}

HiveImpl _registry() {
  final registry = HiveImpl();
  registerIcarusAdapters(registry);
  return registry;
}

HiveImpl _shipped520Registry() {
  final previous = Logger.level;
  Logger.level = LoggerLevel.error;
  try {
    return _registry()
      ..registerAdapter(_Shipped520PlacedUtilityAdapter(), override: true);
  } finally {
    Logger.level = previous;
  }
}

Uint8List _bytes(HiveImpl registry, Object value) =>
    Uint8List.fromList((BinaryWriterImpl(registry)..write(value)).toBytes());

T _across<T extends Object>(HiveImpl from, HiveImpl to, T value) =>
    BinaryReaderImpl(_bytes(from, value), to).read() as T;

/// One zone and one plain rectangle.
StrategyData _strategy() => StrategyData(
      id: 'zone-strategy',
      name: 'Zones',
      mapData: MapValue.ascent,
      versionNumber: Settings.versionNumber,
      lastEdited: DateTime.utc(2026, 11, 11),
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
          utilityData: [_shape('zone', isZone: true), _shape('rectangle')],
          settings: StrategySettings(),
        ),
      ],
    );

void _expectShapes(StrategyData strategy) {
  final utilities = strategy.pages.single.utilityData;
  expect(utilities, hasLength(2));
  expect(utilities.where((u) => u.isZone), hasLength(1));
  expect(utilities.where((u) => !u.isZone), hasLength(1));
  for (final utility in utilities) {
    expect(utility.position, const Offset(30, 40));
    expect(utility.customLength, 18);
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

  group('a rectangle saved before zones were their own shape', () {
    test('opens as a plain rectangle from its JSON', () {
      final opened = PlacedUtility.fromJson(const {
        'id': 'a',
        'type': 'customRectangle',
        'position': {'dx': 30.0, 'dy': 40.0},
        'rotation': 0.0,
        'length': 0.0,
        'customWidth': 6.0,
        'customLength': 18.0,
      });

      expect(opened.isZone, isFalse);
    });

    test('opens as a plain rectangle from Hive written by desktop 5.2.0', () {
      final opened = _across(_shipped520Registry(), _registry(), _shape('a'));

      expect(opened.isZone, isFalse);
      expect(opened.position, const Offset(30, 40));
      expect(opened.customLength, 18);
    });

    test('has no key in its JSON, so its payload is unchanged', () {
      expect(_shape('a').toJson().containsKey('isZone'), isFalse);
    });
  });

  group('a zone', () {
    test('keeps it through its JSON, as a cloud payload carries it', () {
      final json = jsonDecode(jsonEncode(_shape('a', isZone: true).toJson()));

      expect(json['isZone'], isTrue);
      expect(PlacedUtility.fromJson(json).isZone, isTrue);
    });

    test('keeps it through Hive', () {
      final registry = _registry();

      expect(
        _across(registry, registry, _shape('a', isZone: true)).isZone,
        isTrue,
      );
    });

    test('keeps it through every copy of a row', () {
      final item = _shape('a', isZone: true);

      expect(item.copyWith(position: const Offset(1, 1)).isZone, isTrue);
      expect(clonePlacedUtility(item).isZone, isTrue);
      expect(item.deepCopy<PlacedUtility>().isZone, isTrue);
    });

    test('opens in desktop 5.2.0 as the rectangle it is', () {
      final opened = _across(
        _registry(),
        _shipped520Registry(),
        _shape('a', isZone: true),
      );

      expect(opened.type, UtilityType.customRectangle);
      expect(opened.position, const Offset(30, 40));
      expect(opened.customLength, 18);
    });
  });

  test('Hive reopen, a real .ica and a library backup round-trip it', () async {
    final directory = await Directory.systemTemp.createTemp('icarus-zone-');
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
    await box.put('zone-strategy', _strategy());
    await box.close();
    box = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    _expectShapes(box.get('zone-strategy')!);

    final service = StrategyImportExportService(container);
    final exported = await service.zipStrategy(
      id: 'zone-strategy',
      saveDir: directory,
    );
    final result = await service.loadFromFileDrop([XFile(exported)]);

    expect(result.issues, isEmpty);
    expect(result.strategiesImported, 1);
    expect(box.length, 2);
    box.values.forEach(_expectShapes);

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
    box.values.forEach(_expectShapes);
  });
}

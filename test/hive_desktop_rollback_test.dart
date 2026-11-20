import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/src/binary/binary_reader_impl.dart';
import 'package:hive_ce/src/binary/binary_writer_impl.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/folder_icons.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_adapters.dart';
import 'package:icarus/providers/strategy_page.dart';

import 'desktop_4_6_3_adapters_test_support.dart';

Object? _plain(Object? json) => jsonDecode(jsonEncode(json));

void _expectSamePage(StrategyPage actual, StrategyPage expected) {
  expect(
    _plain(actual.toJson('strategy')),
    _plain(expected.toJson('strategy')),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final current = currentRegistry();
  final desktop463 = desktop463Registry();

  test('a page is saved byte for byte as desktop 4.6.3 saves it', () {
    final page = desktop463RichPage();
    expect(writeRecord(current, page), writeRecord(desktop463, page));
  });

  test('desktop 4.6.3 opens a page this build saved, whole', () {
    final page = desktop463RichPage();
    final opened = across(current, desktop463, page);

    _expectSamePage(opened, page);
    expect(opened.drawingData.last, isA<EllipseDrawing>());
    expect(opened.agentData[1], isA<PlacedViewConeAgent>());
    expect(opened.agentData[2], isA<PlacedCircleAgent>());
    expect(
      opened.agentData.map((agent) => agent.weapon),
      [WeaponType.vandal, WeaponType.operator, WeaponType.none],
    );
    expect(opened.abilityData.single.visualState.showRangeFill, isFalse);
    expect(opened.lineUpOrigins.single.agent.weapon, WeaponType.sheriff);
  });

  test('desktop 4.6.3 opens a Warden this build saved as no weapon', () {
    final page = desktop463RichPage();
    page.agentData.first.weapon = WeaponType.warden;
    page.lineUpOrigins.single.agent.weapon = WeaponType.warden;
    final opened = across(current, desktop463, page);

    expect(
      opened.agentData.map((agent) => agent.weapon),
      [WeaponType.none, WeaponType.operator, WeaponType.none],
    );
    expect(opened.lineUpOrigins.single.agent.weapon, WeaponType.none);
    page.agentData.first.weapon = WeaponType.none;
    page.lineUpOrigins.single.agent.weapon = WeaponType.none;
    _expectSamePage(opened, page);
  });

  test('what desktop 4.6.3 saves back, this build opens whole', () {
    final page = desktop463RichPage();
    final rolledBack = across(current, desktop463, page);
    _expectSamePage(across(desktop463, current, rolledBack), page);
  });

  test('every agent 4.6.3 knows, and its abilities, survives a rollback', () {
    final page = desktop463RosterPage([
      for (final type in AgentType.values)
        if (type != AgentType.hush) type,
    ]);

    _expectSamePage(across(current, desktop463, page), page);
  });

  test('desktop 4.6.3 opens a Hush this build saved as Jett', () {
    // 4.6.3 reads an agent index it doesn't know as Jett, and an ability by
    // its agent and index, so Hush's four abilities open as Jett's.
    final opened = across(current, desktop463, desktop463RosterPage([AgentType.hush]));

    _expectSamePage(opened, desktop463RosterPage([AgentType.jett]));
  });

  test('folders keep their exact icon and color through a rollback', () {
    for (final iconId in [
      FolderIconRegistry.defaultId,
      FolderIconRegistry.sentinelRoleId,
      FolderIconRegistry.premierModeId,
    ]) {
      final folder = Folder(
        id: 'folder-$iconId',
        name: 'Execs',
        dateCreated: DateTime.utc(2026, 8, 30),
        iconId: iconId,
        color: FolderColor.custom,
        customColor: const Color(0xFF22C55E),
      );
      expect(writeRecord(current, folder), writeRecord(desktop463, folder));
      final opened = across(current, desktop463, folder);
      expect(opened.iconId, iconId);
      expect(opened.customColor, const Color(0xFF22C55E));
    }
  });

  group('records earlier cloud builds wrote', () {
    BinaryReaderImpl fieldBag(Map<int, Object?> fields) {
      final writer = BinaryWriterImpl(current)..writeByte(fields.length);
      for (final MapEntry(:key, :value) in fields.entries) {
        writer
          ..writeByte(key)
          ..write(value);
      }
      return BinaryReaderImpl(Uint8List.fromList(writer.toBytes()), current);
    }

    test('ability visual state as primitives in fields 10-14', () {
      final ability = desktop463Ability('ability-old-cloud');
      final restored = PlacedAbilityAdapter().read(
        fieldBag({
          0: ability.data,
          1: ability.isAlly,
          2: ability.rotation,
          3: ability.id,
          4: false,
          5: ability.position,
          6: ability.length,
          7: ability.lineUpID,
          8: ability.armLengthsMeters,
          10: false,
          11: false,
          12: true,
          13: false,
          14: false,
        }),
      );

      expect(restored.visualState.showRangeOutline, isFalse);
      expect(restored.visualState.showRangeFill, isFalse);
      expect(restored.visualState.showInnerOutline, isTrue);
      expect(restored.visualState.showInnerFill, isFalse);
      expect(restored.visualState.showVisionCone, isFalse);
    });

    test('folders with the exact icon at 7 and the color at 8', () {
      final restored = FolderAdapter().read(
        fieldBag({
          0: 'Execs',
          1: 'folder-old-cloud',
          2: null,
          3: DateTime.utc(2026, 8, 30),
          4: StoredFolderIcon.fromIconData(Icons.folder),
          5: FolderColor.custom,
          6: const Color(0xFF22C55E),
          7: FolderIconRegistry.sentinelRoleId,
          8: 0xFF22C55E,
        }),
      );

      expect(restored.iconId, FolderIconRegistry.sentinelRoleId);
      expect(restored.customColor, const Color(0xFF22C55E));
    });
  });
}

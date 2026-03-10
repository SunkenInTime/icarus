import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

StrategyData _buildStrategy({
  required String id,
  required String name,
  String? folderId,
}) {
  return StrategyData(
    id: id,
    name: name,
    mapData: MapValue.ascent,
    versionNumber: 1,
    lastEdited: DateTime.utc(2026, 1, 1),
    createdAt: DateTime.utc(2026, 1, 1),
    folderID: folderId,
    pages: [
      StrategyPage(
        id: 'page-1',
        name: 'Page 1',
        drawingData: const [],
        agentData: const [],
        abilityData: const [],
        textData: const [],
        imageData: const [],
        utilityData: const [],
        lineUps: const [],
        sortIndex: 0,
        isAttack: true,
        settings: StrategySettings(),
      ),
    ],
  );
}

void main() {
  group('Temporary strategy integrity helpers', () {
    test('temporary strategy IDs are detected reliably', () {
      final tempId = StrategyProvider.newTemporaryStrategyId();
      expect(StrategyProvider.isTemporaryStrategyId(tempId), isTrue);
      expect(StrategyProvider.isTemporaryStrategyId('saved-id-1'), isFalse);
    });

    test('overwrite from temporary preserves original identity', () {
      final original = _buildStrategy(
        id: 'saved-id',
        name: 'Saved Name',
        folderId: 'folder-A',
      );
      final temporary = _buildStrategy(
        id: '_temp_abc',
        name: 'Saved Name (Temporary Copy)',
        folderId: null,
      ).copyWith(
        mapData: MapValue.bind,
      );

      final merged = StrategyProvider.buildOverwriteFromTemporary(
        original: original,
        temporary: temporary,
      );

      expect(merged.id, original.id);
      expect(merged.name, original.name);
      expect(merged.folderID, original.folderID);
      expect(merged.createdAt, original.createdAt);
      expect(merged.mapData, MapValue.bind);
    });

    test('save as new from temporary produces distinct document', () {
      final temporary = _buildStrategy(
        id: '_temp_abc',
        name: 'Quick Board',
      ).copyWith(mapData: MapValue.pearl);

      final saved = StrategyProvider.buildSavedCopyFromTemporary(
        temporary: temporary,
        id: 'new-id',
        name: 'Final Strategy',
        folderID: 'folder-X',
      );

      expect(saved.id, 'new-id');
      expect(saved.name, 'Final Strategy');
      expect(saved.folderID, 'folder-X');
      expect(saved.mapData, MapValue.pearl);
      expect(saved.createdAt, isNot(temporary.createdAt));
    });
  });
}

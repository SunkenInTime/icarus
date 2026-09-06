import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/strategy_filter_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/widgets/library_entries.dart';

void main() {
  test('a strategy present in both stores shows once, as its cloud copy', () {
    final local = LibraryStrategyRow.local(
      _localStrategy('shared-id', 'Local copy'),
      showDeviceBadge: true,
    );
    final onlyLocal = LibraryStrategyRow.local(
      _localStrategy('local-only', 'Mine'),
      showDeviceBadge: true,
    );
    final cloud = LibraryStrategyRow.cloud(_cloudStrategy('shared-id', 'Cloud'));

    final merged = mergeLibraryStrategies(
      local: [local, onlyLocal],
      cloud: [cloud],
    );

    expect(merged.map((row) => row.id), ['shared-id', 'local-only']);
    expect(merged.first.cloud, isNotNull);
    expect(merged.last.showDeviceBadge, isTrue);
  });

  test('folders keep their store after merging', () {
    final merged = mergeLibraryFolders(
      local: [_folderRow('a', LibraryWorkspace.local)],
      cloud: [_folderRow('b', LibraryWorkspace.cloud)],
    );

    expect(
      merged.map((row) => row.store),
      [LibraryWorkspace.cloud, LibraryWorkspace.local],
    );
  });

  test('sorting mixes both stores on the chosen field', () {
    final rows = [
      LibraryStrategyRow.local(
        _localStrategy('b', 'Bravo', created: DateTime(2024, 1, 2)),
        showDeviceBadge: false,
      ),
      LibraryStrategyRow.cloud(
        _cloudStrategy('a', 'Alpha', created: DateTime(2024, 1, 3)),
      ),
      LibraryStrategyRow.local(
        _localStrategy('c', 'Charlie', created: DateTime(2024, 1, 1)),
        showDeviceBadge: false,
      ),
    ];

    final byName = sortLibraryStrategies(
      rows,
      StrategyFilterState(
        sortBy: SortBy.alphabetical,
        sortOrder: SortOrder.ascending,
      ),
    );
    expect(byName.map((row) => row.id), ['a', 'b', 'c']);

    final newestFirst = sortLibraryStrategies(
      rows,
      StrategyFilterState(
        sortBy: SortBy.dateCreated,
        sortOrder: SortOrder.descending,
      ),
    );
    expect(newestFirst.map((row) => row.id), ['a', 'b', 'c']);
  });
}

StrategyData _localStrategy(String id, String name, {DateTime? created}) {
  final at = created ?? DateTime(2024, 1, 1);
  return StrategyData(
    id: id,
    name: name,
    mapData: MapValue.ascent,
    versionNumber: 1,
    folderID: null,
    pages: const [],
    createdAt: at,
    lastEdited: at,
  );
}

CloudStrategyEntry _cloudStrategy(String id, String name, {DateTime? created}) {
  return (
    strategy: _localStrategy(id, name, created: created),
    revision: 1,
    role: 'owner',
    attackLabel: 'Attack',
  );
}

LibraryFolderRow _folderRow(String id, LibraryWorkspace store) {
  return LibraryFolderRow(
    folder: Folder(
      name: id,
      id: id,
      dateCreated: DateTime(2024, 1, 1),
      color: FolderColor.blue,
    ),
    store: store,
    lastUpdated: DateTime(2024, 1, 1),
  );
}

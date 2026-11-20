import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_payload_upgrade.dart';
import 'package:icarus/collab/collab_models.dart' as app;
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_rows/strategy_comparison.dart';
import 'package:icarus/strategy/strategy_cloud_migration.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:path/path.dart' as path;

import 'generated_strategies.dart';
import 'library_sources.dart';

StrategyRowsMade rowsOf(StrategyData strategy) =>
    switch (strategyToRows(strategy)) {
      StrategyRowsMade() && final made => made,
      StrategyRowsRefused(:final problems) =>
        throw TestFailure('refused: $problems'),
    };

final class MovedToCloud {
  const MovedToCloud(this.rows, this.ids);

  final StrategyRowSet rows;
  final MovedItemIds ids;
}

MovedToCloud movedToCloud(StrategyData strategy, StrategyRowSet mine) {
  var rows = StrategyRowSet(
    strategy: mine.strategy,
    pages: mine.pages,
    settings: mine.settings,
  );
  final ids = MovedItemIds();
  final ops = <app.StrategyOp>[];
  for (final page in strategy.pages) {
    appendMovedPageOps(ops, page, cloudPageId: page.id, ids: ids);
  }
  for (final op in ops) {
    final decoded = StrategyOp.decode(op.toConvexJson());
    final read = switch (decoded) {
      Read(:final value) => value,
      CouldNotRead(:final problem) => throw TestFailure(problem),
    };
    switch (applyOp(rows, read)) {
      case OpApplied(rows: final written):
        rows = rows.withRows(written);
      case final other:
        throw TestFailure('${op.toConvexJson()['type']}: $other');
    }
  }
  return MovedToCloud(rows, ids);
}

Map<String, String> localPictureOf(MovedItemIds ids) => {
      for (final MapEntry(:key, :value) in ids.pictures.entries)
        value.cloudId: key,
    };

Map<String, Object?> elementInLocalTerms(
  Map<String, Object?> data, {
  required String localId,
  required Map<String, String> localPicture,
}) {
  final picture = data['assetId'];
  return {
    ...data,
    'id': localId,
    if (picture is String) 'assetId': localPicture[picture] ?? picture,
  };
}

List<String> elementDisagreements(
  StrategyRowSet mine,
  MovedToCloud cloud,
) {
  final localPicture = localPictureOf(cloud.ids);
  final found = <String>[];
  for (final page in mine.pages) {
    List<LiveElement> ordered(StrategyRowSet rows) =>
        rows.elementsOn(page.publicId).cast<LiveElement>().toList()
          ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    final ours = ordered(mine);
    final theirs = ordered(cloud.rows);
    expect(theirs.length, ours.length, reason: 'page ${page.publicId}');
    for (final (index, our) in ours.indexed) {
      final their = theirs[index];
      final ourData = Map<String, Object?>.from(our.payload.data);
      if (ourData['assetId'] == null && our.payload.kind == ElementKind.image) {
        ourData['assetId'] = ourData['id'];
      }
      final theirData = elementInLocalTerms(
        their.payload.data,
        localId: ourData['id']! as String,
        localPicture: localPicture,
      );
      for (final key in {...ourData.keys, ...theirData.keys}) {
        if (!sameJsonValue(ourData[key], theirData[key]) ||
            ourData.containsKey(key) != theirData.containsKey(key)) {
          found.add('${our.payload.kind.name}.$key');
        }
      }
      expect(
        (
          their.sortIndex,
          their.revision,
          their.payload.kind,
          their.payload.payloadVersion
        ),
        (
          our.sortIndex,
          our.revision,
          our.payload.kind,
          our.payload.payloadVersion
        ),
      );
    }
  }
  return found;
}

bool sameJsonValue(Object? left, Object? right) => switch ((left, right)) {
      (final Map<Object?, Object?> l, final Map<Object?, Object?> r) =>
        l.length == r.length &&
            l.keys.every((key) => sameJsonValue(l[key], r[key])),
      (final List<Object?> l, final List<Object?> r) => l.length == r.length &&
          [for (var i = 0; i < l.length; i++) i]
              .every((i) => sameJsonValue(l[i], r[i])),
      _ => left == right,
    };

Object? lineupInLocalTerms(Object? json, Map<String, String> localPicture) =>
    switch (json) {
      {'id': final String id, 'fileExtension': final String extension} => {
          'id': localPicture[id] ?? id,
          'fileExtension': extension,
        },
      final Map<String, Object?> map => {
          for (final MapEntry(:key, :value) in map.entries)
            key: lineupInLocalTerms(value, localPicture),
        },
      final List<Object?> list => [
          for (final item in list) lineupInLocalTerms(item, localPicture),
        ],
      _ => json,
    };

void expectSameLineupGroups(StrategyRowSet mine, MovedToCloud cloud) {
  final localPicture = localPictureOf(cloud.ids);
  for (final page in mine.pages) {
    List<ReadableLineupGroupRow> ordered(StrategyRowSet rows) => rows
        .lineupGroupsOn(page.publicId)
        .cast<ReadableLineupGroupRow>()
        .toList()
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    final ours = ordered(mine);
    final theirs = ordered(cloud.rows);
    expect(theirs.length, ours.length, reason: 'page ${page.publicId}');
    for (final (index, our) in ours.indexed) {
      final their = theirs[index];
      final theirData = lineupInLocalTerms(their.payload.data, localPicture)!
          as Map<String, Object?>;
      final linkIds = [
        for (final link in theirData['links']! as List)
          (link as Map<String, Object?>)['id'],
      ];
      final chosenByCloud = linkIds.contains(their.publicId);
      expect(
        sameJsonValue(
          {...our.payload.data, if (!chosenByCloud) 'id': null},
          {...theirData, if (!chosenByCloud) 'id': null},
        ),
        isTrue,
        reason: 'page ${page.publicId} group $index',
      );
      if (chosenByCloud) expect(our.publicId, their.publicId);
      expect(
        (their.sortIndex, their.revision, their.payload.payloadVersion),
        (our.sortIndex, our.revision, our.payload.payloadVersion),
      );
    }
  }
}

app.RemoteFullStrategySnapshot snapshotOf(StrategyRowSet rows) {
  final strategy = rows.strategy;
  final at = DateTime.utc(2026, 5, 6);
  List<T> ordered<T extends Object>(
    Iterable<T> items,
    int Function(T item) sortIndex,
  ) =>
      items.toList()..sort((a, b) => sortIndex(a).compareTo(sortIndex(b)));
  return app.RemoteFullStrategySnapshot(
    header: app.RemoteStrategyHeader(
      publicId: strategy.publicId,
      name: strategy.name,
      mapData: strategy.mapData,
      revision: strategy.revision,
      createdAt: at,
      updatedAt: at,
      themeProfileId: strategy.themeProfileId,
      themeOverridePalette: strategy.themeOverridePalette?.toJson(),
    ),
    pages: [
      for (final page in rows.pages.cast<ReadablePageRow>())
        app.RemoteFullPage(
          page: app.RemotePage(
            publicId: page.publicId,
            strategyPublicId: page.strategyPublicId,
            name: page.name,
            isAutoNamed: page.isAutoNamed,
            sortIndex: page.sortIndex,
            isAttack: page.isAttack,
            revision: page.revision,
            createdAt: at,
            updatedAt: at,
          ),
          content: app.RemotePageContent(
            revision: 1,
            createdAt: at,
            updatedAt: at,
            settings: (rows.settingsOf(page.publicId) as ReadablePageSettings?)
                ?.settings
                ?.toJson(),
          ),
        ),
    ],
    elementsByPage: {
      for (final page in rows.pages)
        page.publicId: [
          for (final element in ordered(
            rows.elementsOn(page.publicId).cast<LiveElement>(),
            (element) => element.sortIndex,
          ))
            app.RemoteElement(
              publicId: element.publicId,
              strategyPublicId: strategy.publicId,
              pagePublicId: page.publicId,
              elementType: element.payload.kind.name,
              payload: element.payload.toJson(),
              sortIndex: element.sortIndex,
              revision: element.revision,
              deleted: false,
            ),
        ],
    },
    lineupsByPage: {
      for (final page in rows.pages)
        page.publicId: [
          for (final group in ordered(
            rows.lineupGroupsOn(page.publicId).cast<ReadableLineupGroupRow>(),
            (group) => group.sortIndex,
          ))
            app.RemoteLineup(
              publicId: group.publicId,
              strategyPublicId: strategy.publicId,
              pagePublicId: page.publicId,
              payload: group.payload.toJson(),
              sortIndex: group.sortIndex,
              revision: group.revision,
              deleted: false,
            ),
        ],
    },
    assetsById: const {},
  );
}

Future<List<(String, StrategyData)>> strategiesToCompare() async {
  final files = icaFilesUnder(
    Directory(path.join('test', 'fixtures', 'strategy_integrity')),
  );
  return [
    for (final (index, strategy) in (await importIcaFiles(files)).indexed)
      (path.basename(files[index].path), strategy),
    for (final optionals in Optionals.values)
      ('generated, optionals ${optionals.name}', generatedStrategy(optionals)),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => appProviderContainer = ProviderContainer());
  tearDownAll(() => appProviderContainer.dispose());

  test(
      'the ops that move a strategy to the cloud, applied to an empty one, '
      'give these element and lineup group rows, but for the image link',
      () async {
    for (final (name, strategy) in await strategiesToCompare()) {
      final mine = rowsOf(strategy).rows;
      final cloud = movedToCloud(strategy, mine);
      final hasLink = [
        for (final page in strategy.pages)
          for (final image in page.imageData) image.link,
      ].any((link) => link.isNotEmpty);
      final imageCount = [
        for (final page in strategy.pages) ...page.imageData,
      ].length;
      expect(
        elementDisagreements(mine, cloud),
        List.filled(imageCount, 'image.link'),
        reason: '$name, links set: $hasLink',
      );
      expectSameLineupGroups(mine, cloud);
    }
  });

  test(
      'the cloud export reads these rows as the same strategy, but for its '
      'folder and times', () async {
    for (final (name, strategy) in await strategiesToCompare()) {
      final mine = rowsOf(strategy).rows;
      final exported =
          StrategyImportExportService.strategyDataFromRemoteSnapshot(
        snapshotOf(mine),
      );
      final mineBack = switch (strategyFromRows(
        mine,
        StrategyTimes(
          createdAt: exported.createdAt,
          lastEdited: exported.lastEdited,
        ),
      )) {
        StrategyDataMade(:final strategy) => strategy,
        StrategyDataRefused(:final problems) =>
          throw TestFailure('refused: $problems'),
      };
      expect(
        strategyDifferences(mineBack, exported).map((d) => '$d'),
        [if (strategy.folderID != null) 'value folderID'],
        reason: name,
      );
    }
  });

  test(
      'a Paranoia saved before its size was corrected is read as the cloud '
      'reads it', () {
    final mine = rowsOf(generatedStrategy(Optionals.set)).rows;
    final paranoias = [
      for (final element in mine.elements.cast<LiveElement>())
        if (element.payload.payloadVersion == 2) element,
    ];
    expect(paranoias, isNotEmpty);
    final old = mine.withRows([
      for (final element in paranoias)
        LiveElement(
          publicId: element.publicId,
          pagePublicId: element.pagePublicId,
          payload: ElementPayload(
            kind: element.payload.kind,
            payloadVersion: 1,
            data: element.payload.data,
          ),
          sortIndex: element.sortIndex,
          revision: element.revision,
        ),
    ]);
    final exported = StrategyImportExportService.strategyDataFromRemoteSnapshot(
      upgradeRemoteFullSnapshot(snapshotOf(old)),
    );
    final mineBack = switch (strategyFromRows(
      old,
      StrategyTimes(
        createdAt: exported.createdAt,
        lastEdited: exported.lastEdited,
      ),
    )) {
      StrategyDataMade(:final strategy) => strategy,
      StrategyDataRefused(:final problems) =>
        throw TestFailure('refused: $problems'),
    };
    expect(
      strategyDifferences(mineBack, exported).map((d) => '$d'),
      ['value folderID'],
    );
    final corrected = mineBack.pages.first.abilityData
        .firstWhere((ability) => ability.id == 'page-attack-paranoia');
    final original = generatedStrategy(Optionals.set)
        .pages
        .first
        .abilityData
        .firstWhere((ability) => ability.id == 'page-attack-paranoia');
    expect(corrected.position, isNot(original.position));
  });
}

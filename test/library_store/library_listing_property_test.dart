import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/hive_reads.dart';
import 'package:icarus/library_store/library_box_writes.dart';
import 'package:icarus/library_store/library_listing.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/local_library_view.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

import '../library_rows/generated_strategies.dart';
import 'gated_engine.dart';
import 'hive_scratch.dart';
import 'tile_parity.dart';

String _tile(LocalStrategySummary strategy) => [
      strategy.id,
      strategy.name,
      strategy.mapData.name,
      strategy.folderId,
      strategy.createdAt.millisecondsSinceEpoch,
      strategy.lastEdited.millisecondsSinceEpoch,
      strategy.sides.name,
      strategy.opensOnAttack,
      strategy.agentTypes.map((agent) => agent.name).join(' '),
    ].join(' | ');

String _folder(Folder folder) => [
      folder.id,
      folder.name,
      folder.parentID,
      folder.dateCreated.millisecondsSinceEpoch,
      folder.iconId,
      folder.color.name,
      folder.customColor?.toARGB32(),
    ].join(' | ');

StrategyData _withoutDrawings(StrategyData strategy) => strategy.copyWith(
      pages: [
        for (final page in strategy.pages) page.copyWith(drawingData: const []),
      ],
    );

StrategyData _pagesOutOfOrder(String id) {
  final bare = _withoutDrawings(generatedStrategy(Optionals.unset));
  final page = bare.pages.first;
  return bare.copyWith(
    id: id,
    name: 'Pages out of order',
    pages: [
      page.copyWith(id: '$id-attack', sortIndex: 1, isAttack: true),
      page.copyWith(id: '$id-defend', sortIndex: 0, isAttack: false),
    ],
  );
}

StrategyData _portraitsCrossed(String id) {
  final bare = _withoutDrawings(generatedStrategy(Optionals.unset));
  final page = bare.pages.first;
  PlacedAbility landingAbility(String landing) => PlacedAbility(
        id: '$landing-ability',
        data: AgentData.agents[AgentType.sova]!.abilities.first,
        position: const Offset(300, 300),
      );
  return bare.copyWith(
    id: id,
    name: 'Portraits crossed',
    pages: [
      page.copyWith(
        agentData: const [],
        lineUpGraph: LineUpGraph(
          origins: [
            LineUpOrigin(
              id: '$id-sova',
              agent: PlacedAgent(
                id: '$id-sova-agent',
                type: AgentType.sova,
                position: const Offset(100, 200),
              ),
            ),
            LineUpOrigin(
              id: '$id-fade',
              agent: PlacedAgent(
                id: '$id-fade-agent',
                type: AgentType.fade,
                position: const Offset(140, 200),
              ),
            ),
          ],
          landings: [
            LineUpLanding(
                id: '$id-land-1', ability: landingAbility('$id-land-1')),
            LineUpLanding(
                id: '$id-land-2', ability: landingAbility('$id-land-2')),
          ],
          links: [
            LineUpLink(
              id: '$id-link-fade',
              originId: '$id-fade',
              landingId: '$id-land-2',
            ),
            LineUpLink(
              id: '$id-link-sova',
              originId: '$id-sova',
              landingId: '$id-land-1',
            ),
          ],
        ),
      ),
      ...bare.pages.skip(1),
    ],
  );
}

final _shapes = [
  _withoutDrawings(generatedStrategy(Optionals.set)),
  _withoutDrawings(generatedStrategy(Optionals.unset)),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('icarus-property-');
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(20)) registerIcarusAdapters(Hive);
  });
  tearDown(() async {
    LocalLibrary.follower = null;
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
      'after every event of a session, with the mirror\'s commits held, released and failed at random, the list drawn in read mode is the list Hive holds, field for field and in order',
      () async {
    var checks = 0;
    var drawnFromStore = 0;
    var foldersFromStore = 0;
    var crossedFromStore = 0;
    var reorderedFromStore = 0;
    var keptStrategiesSeen = 0;
    var inTheCloudSeen = 0;
    var keptFoldersSeen = 0;
    for (var seed = 0; seed < 24; seed++) {
      final random = Random(seed);
      await openScratchHive(
        directory,
        strategies: [
          for (var n = 0; n < 6; n++)
            _shapes[n % 2].copyWith(
              id: 's$seed-$n',
              name: 'Seeded $n',
              folderID: n.isEven ? 'f$seed-root' : null,
              lastEdited: DateTime.utc(2026, 1, 1, 0, 0, n),
            ),
          _portraitsCrossed('s$seed-crossed'),
          _pagesOutOfOrder('s$seed-reordered'),
          _shapes[1].copyWith(id: 's$seed-shared', name: 'Also in the cloud'),
        ],
        folders: [
          Folder(name: 'Root', id: 'f$seed-root', dateCreated: DateTime(2026)),
          Folder(
              name: 'Spare', id: 'f$seed-spare', dateCreated: DateTime(2026)),
        ],
      );
      final strategyBox = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
      final folderBox = Hive.box<Folder>(HiveBoxNames.foldersBox);
      await strategyBox.add(
        _shapes[0].copyWith(id: 's$seed-numbered', name: 'Under a number'),
      );
      await strategyBox.put(
        's$seed-alias',
        _shapes[1].copyWith(id: 's$seed-aliased', name: 'Under another key'),
      );
      await strategyBox.put(
        's$seed-twin',
        _shapes[0].copyWith(id: 's$seed-1', name: 'Twin of 1'),
      );
      await folderBox.add(
        Folder(
            name: 'Numbered',
            id: 'f$seed-numbered',
            dateCreated: DateTime(2026)),
      );
      await folderBox.put(
        'f$seed-alias',
        Folder(
            name: 'Aliased', id: 'f$seed-aliased', dateCreated: DateTime(2026)),
      );
      await folderBox.put(
        'f$seed-twin',
        Folder(
            name: 'Twin spare',
            id: 'f$seed-spare',
            dateCreated: DateTime(2026)),
      );
      final gate = CommitGate();
      final store = switch (await LibraryStore.open(
        GatedEngine(MemoryEngine(MemoryStorage()), gate),
        canRead: appCanRead,
      )) {
        StoreOpened(:final store) => store,
        StoreNotOpened(:final problem) => fail('$problem'),
      };
      for (final id in ['s$seed-shared', 's$seed-cloud-only']) {
        final rows = switch (strategyToRows(
            strategyAsHiveHoldsIt(_shapes[0].copyWith(id: id)))) {
          StrategyRowsMade(:final rows) => rows,
          StrategyRowsRefused(:final problems) => fail('$problems'),
        };
        expect(
          await store.addCloudStrategy(
            Account('account-a'),
            HeaderRead(
              strategy: rows.strategy,
              pages: [
                for (final page in rows.pages) bornIn(page, 1) as PageRow,
              ],
              settings: [
                for (final row in rows.settings)
                  bornIn(row, 1) as PageSettingsRow,
              ],
            ),
            const [],
          ),
          isA<Saved<StrategySummary, LibraryRefusal>>(),
        );
      }
      final mirror = StoreMirror(
        reads: HiveReads(),
        betweenAnimations: () =>
            Future<void>.delayed(Duration(microseconds: random.nextInt(300))),
      );
      final hive = HiveLibraryListing();
      final listing = StoreLibraryListing(
        HiveLibraryListing(),
        clock: () => Duration.zero,
      )..follow(mirror);
      LocalLibrary.follower = mirror;
      final keptStrategies = mirror.reads.names.strategies.keptIds;
      final keptFolders = mirror.reads.names.folders.keptIds;
      expect(keptStrategies, {'s$seed-numbered', 's$seed-aliased', 's$seed-1'});
      expect(
          keptFolders, {'f$seed-numbered', 'f$seed-aliased', 'f$seed-spare'});

      bool fromStoreByRule(String id, {required bool folder}) =>
          switch (listing.source) {
            ListFromStore(:final mirror) => folder
                ? !mirror.foldersNotKnownEqual.contains(id) &&
                    !listing.foldersNotInStore.contains(id)
                : !mirror.strategiesNotKnownEqual.contains(id) &&
                    !listing.strategiesNotInStore.contains(id),
            ListFromHive() => false,
          };

      String expectedTile(LocalStrategySummary fromHive) {
        if (!fromStoreByRule(fromHive.id, folder: false)) {
          return _tile(fromHive);
        }
        final stored = const LocalLibrary().storedStrategy(fromHive.id)!;
        final inGroups = HiveLibraryListing.asStored(inGroupOrder(stored));
        final asTheStoreHasIt =
            HiveLibraryListing.asStored(inGroupOrder(inPageOrder(stored)));
        if (_tile(inGroups) != _tile(fromHive)) crossedFromStore++;
        if (_tile(asTheStoreHasIt) != _tile(inGroups)) reorderedFromStore++;
        return _tile(asTheStoreHasIt);
      }

      void check(String when) {
        checks++;
        final rows = listing.strategies.value.toList();
        expect(
          [for (final strategy in rows) _tile(strategy)],
          [
            for (final strategy in hive.strategiesAsStored())
              expectedTile(strategy),
          ],
          reason: 'seed $seed, $when',
        );
        for (final row in rows) {
          expect(
            row.notInStore,
            switch (listing.source) {
              ListFromStore(:final mirror) =>
                mirror.refusedStrategies.containsKey(row.id) ||
                    keptStrategies.contains(row.id) ||
                    row.id == 's$seed-shared',
              ListFromHive() => false,
            },
            reason: 'seed $seed, $when, mark on ${row.id}',
          );
          final fromStore = listing.drewFromStore(row);
          if (fromStore) drawnFromStore++;
          if (row.id == 's$seed-shared') {
            inTheCloudSeen++;
            expect(fromStore, isFalse, reason: 'seed $seed, $when, ${row.id}');
          }
          if (keptStrategies.contains(row.id)) {
            keptStrategiesSeen++;
            expect(fromStore, isFalse, reason: 'seed $seed, $when, ${row.id}');
          }
          expect(
            fromStore,
            fromStoreByRule(row.id, folder: false),
            reason: 'seed $seed, $when, source of ${row.id}',
          );
        }
        expect(
          listing.strategiesNotInStore,
          isNot(contains('s$seed-cloud-only')),
          reason: 'seed $seed, $when',
        );
        expect(
          rows.where((row) => row.id == 's$seed-cloud-only'),
          isEmpty,
          reason: 'seed $seed, $when',
        );
        final folders = listing.folders.value.toList();
        expect(
          [for (final folder in folders) _folder(folder)],
          [for (final folder in hive.foldersAsStored()) _folder(folder)],
          reason: 'seed $seed, $when',
        );
        for (final folder in folders) {
          final fromStore = listing.drewFromStore(folder);
          if (fromStore) foldersFromStore++;
          if (keptFolders.contains(folder.id)) {
            keptFoldersSeen++;
            expect(fromStore, isFalse,
                reason: 'seed $seed, $when, ${folder.id}');
          }
          expect(
            fromStore,
            fromStoreByRule(folder.id, folder: true),
            reason: 'seed $seed, $when, source of folder ${folder.id}',
          );
        }
        for (final strategy in hive.strategiesAsStored()) {
          final byId = listing.strategy(strategy.id);
          if (keptStrategies.contains(strategy.id)) {
            final underThatKey =
                hive.strategyAsStored(strategy.id, notInStore: const {});
            expect(
              byId == null ? null : _tile(byId),
              underThatKey == null ? null : _tile(underThatKey),
              reason: 'seed $seed, $when, ${strategy.id} looked up by id',
            );
            continue;
          }
          expect(
            _tile(byId!),
            expectedTile(strategy),
            reason: 'seed $seed, $when, ${strategy.id}',
          );
        }
        for (final folder in hive.foldersAsStored()) {
          final byId = listing.folder(folder.id);
          final expected = keptFolders.contains(folder.id)
              ? hive.folderAsStored(folder.id)
              : folder;
          expect(
            byId == null ? null : _folder(byId),
            expected == null ? null : _folder(expected),
            reason: 'seed $seed, $when, ${folder.id}',
          );
          expect(
            [for (final child in listing.folderChildren(folder.id)) child.id],
            [
              for (final child in hive.folderChildren(folder.id)) child.id,
            ],
            reason: 'seed $seed, $when, children of ${folder.id}',
          );
        }
      }

      final heard = mirror.updates.listen((_) => check('as the mirror moved'));
      final storeHeard =
          store.changes.listen((_) => check('as the store changed'));
      final writes = LibraryBoxWrites();
      final copying = mirror.copyThenFollow(store, writes: writes);
      check('as the start-up copy began');
      await copying;
      await writes.stop();
      check('after the start-up copy');

      var made = 0;
      List<String> strategyIds() =>
          [for (final strategy in hive.strategiesAsStored()) strategy.id];
      List<String> folderIds() =>
          [for (final folder in hive.folders.value) folder.id];
      String? pick(List<String> ids) =>
          ids.isEmpty ? null : ids[random.nextInt(ids.length)];
      var deletedFolder = 'never-held';

      for (var step = 0; step < 40; step++) {
        final Future<Object?> action;
        final String what;
        switch (random.nextInt(12)) {
          case 0 || 1:
            final id = 's$seed-new-${made++}';
            what = 'create $id';
            final folder = pick(folderIds());
            final fresh = _shapes[1].copyWith(
              id: id,
              name: 'Made $made',
              lastEdited: DateTime.now(),
            );
            action = const LocalLibrary().addStrategy(
              folder == null ? fresh : fresh.copyWith(folderID: folder),
            );
          case 2 || 3:
            final id = pick(strategyIds()) ?? 'missing';
            what = 'rename $id';
            action = switch (const LocalLibrary().storedStrategy(id)) {
              final stored? =>
                const LocalLibrary().renameStrategy(stored, 'Renamed $step'),
              null => Future.value(const LibraryWritten()),
            };
          case 4:
            final id = pick(strategyIds()) ?? 'missing';
            final to = switch (random.nextInt(3)) {
              0 => null,
              1 => deletedFolder,
              _ => pick(folderIds()),
            };
            what = 'move $id to $to';
            action = switch (const LocalLibrary().storedStrategy(id)) {
              final stored? => const LocalLibrary().moveStrategy(stored, to),
              null => Future.value(const LibraryWritten()),
            };
          case 5:
            final id = pick(strategyIds()) ?? 'missing';
            what = 'delete $id';
            action = const LocalLibrary().deleteStrategy(id);
          case 6:
            final id = pick(strategyIds());
            final original =
                id == null ? null : const LocalLibrary().storedStrategy(id);
            final copy = 's$seed-copy-${made++}';
            what = 'duplicate $id as $copy';
            action = original == null
                ? Future.value()
                : const LocalLibrary().addStrategy(
                    original.copyWith(id: copy, name: '${original.name} copy'),
                  );
          case 7:
            final id = 'f$seed-${made++}';
            what = 'create folder $id';
            action = const LocalLibrary().addFolder(
              Folder(
                name: 'Folder $made',
                id: id,
                dateCreated: DateTime.now(),
                parentID: pick(folderIds()),
              ),
            );
          case 8:
            final id = pick(folderIds());
            final stored =
                id == null ? null : const LocalLibrary().storedFolder(id);
            what = 'restyle folder $id';
            action = stored == null
                ? Future.value()
                : const LocalLibrary().restyleFolder(
                    stored,
                    name: 'Restyled $step',
                    iconId: 1,
                    customColor: null,
                    color: FolderColor.values[random.nextInt(5)],
                  );
          case 9:
            final id = pick(folderIds());
            if (id == null) {
              what = 'nothing to delete';
              action = Future.value();
            } else {
              deletedFolder = id;
              final tree = <String>{id};
              for (var grew = true; grew;) {
                grew = false;
                for (final folder in hive.folders.value) {
                  if (folder.parentID case final parent?
                      when tree.contains(parent)) {
                    grew = tree.add(folder.id) || grew;
                  }
                }
              }
              what = 'delete folder $id with what is in it';
              action = const LocalLibrary().deleteFoldersWithStrategies(
                folderIds: tree.toList(),
                strategyIds: [
                  for (final strategy in hive.strategiesAsStored())
                    if (tree.contains(strategy.folderId)) strategy.id,
                ],
              );
            }
          case 10:
            what = gate.isHeld ? 'release commits' : 'hold commits';
            gate.isHeld ? gate.release() : gate.hold();
            action = Future.value();
          case _:
            what = 'let the mirror run';
            action = pumpEventQueue(times: random.nextInt(20));
        }
        check('step $step, $what, as it starts');
        await action;
        check('step $step, $what, once Hive answered');
        if (step == 30 && seed.isOdd) gate.failNext = true;
      }
      gate.release();
      await mirror.drained().timeout(const Duration(seconds: 10));
      check('after the session drained');
      await heard.cancel();
      await storeHeard.cancel();
      await store.close();
      LocalLibrary.follower = null;
      await Hive.close();
      await directory.delete(recursive: true);
      await directory.create();
      Hive.init(directory.path);
    }
    expect(checks, greaterThan(2000));
    expect(drawnFromStore, greaterThan(5000));
    expect(foldersFromStore, greaterThan(1000));
    expect(crossedFromStore, greaterThan(100));
    expect(reorderedFromStore, greaterThan(100));
    expect(keptStrategiesSeen, greaterThan(1000));
    expect(keptFoldersSeen, greaterThan(1000));
    expect(inTheCloudSeen, greaterThan(500));
  }, timeout: const Timeout(Duration(minutes: 5)));
}

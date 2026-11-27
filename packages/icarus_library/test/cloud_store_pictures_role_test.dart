import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/codec.dart';
import 'package:test/test.dart';

import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

final area = strategyArea(strategyId);

String assetsName(String page) => 'assets/${digestOf(page)}';

PictureAsset picture(String extension, {String status = 'active'}) =>
    PictureAsset(
      provider: 'r2',
      uploadStatus: status,
      fileExtension: extension,
      mimeType: 'image/$extension',
      width: 640,
      height: 360,
      byteSize: 2048,
      uploadedAt: DateTime.utc(2026, 11, 1),
      url: 'https://images.example/$extension',
    );

LiveElement image(String id, {String pageId = 'page-a', String? pictureId}) =>
    LiveElement(
      publicId: id,
      pagePublicId: pageId,
      payload: ElementPayload(
        kind: ElementKind.image,
        payloadVersion: 1,
        data: {
          'id': id,
          'elementType': 'image',
          'assetId': ?pictureId,
          'fileExtension': 'png',
        },
      ),
      sortIndex: 1,
      revision: 1,
      unknownFields: jsonObject({'createdAt': fixtureLife}),
    );

StrategyRowSet withImage() => strategyRows(
  elements: [
    element('e1'),
    image('i1', pictureId: 'p1'),
    element('e3', pageId: 'page-b'),
  ],
);

HeaderRead listAs(StrategyRowSet rows, StrategyRole role) => HeaderRead(
  strategy: rows.strategy,
  pages: rows.pages.toList(),
  settings: rows.settings.toList(),
  role: role,
);

PageRead pageWith(
  StrategyRowSet rows,
  String page,
  Map<String, PictureAsset> pictures,
) {
  final read = pageReadOf(rows, page) as PageRead;
  return PageRead(
    page: read.page,
    elements: read.elements,
    lineupGroups: read.lineupGroups,
    pictures: pictures,
  );
}

const editor = RoleKnown(CloudRole.editor);
const viewer = RoleKnown(CloudRole.viewer);

Future<LibraryStore> adopted(
  MemoryStorage storage, {
  StrategyRole role = editor,
  Map<String, PictureAsset>? pictures,
}) async {
  final store = await openCloudStore(MemoryEngine(storage));
  final rows = withImage();
  savedValue(
    await store.addCloudStrategy(
      testAccount,
      stamped(listAs(rows, role)),
      stampedPages([
        pageWith(rows, 'page-a', pictures ?? {'p1': picture('png')}),
        pageWith(rows, 'page-b', const {}),
      ]),
    ),
  );
  return store;
}

Future<PageContent> pageIn(LibraryStore store, String page) async =>
    pageOf(await store.readPage(strategyId, page));

Map<String, PictureAsset> picturesOn(PageContent page) =>
    switch (page.content) {
      ContentShown(:final pictures) => pictures,
      ContentNotRead() => fail('expected the page content to be read'),
    };

Future<LibraryStore> reopened(LibraryStore store, MemoryStorage storage) async {
  await store.close();
  return openCloudStore(MemoryEngine(storage));
}

void main() {
  group('the codec', () {
    test(
      'a facts row written before roles were kept reads as role unknown',
      () {
        const before =
            '{"version":1,"account":"account-a","presence":"present",'
            '"accessLostAt":0,"accessConfirmedAt":0}';
        expect(
          factsFromText(before),
          isA<CloudRowRead<CloudFacts>>().having(
            (read) => read.value.role,
            'role',
            const RoleUnknown(),
          ),
        );
      },
    );

    test('a role reads back as written, and a role this build does not name '
        'reads as unknown rather than holding the queue', () {
      final text = jsonEncode(
        factsToJson(testAccount, StrategyFacts.fresh, role: viewer),
      );
      expect(
        (factsFromText(text) as CloudRowRead<CloudFacts>).value,
        CloudFacts(testAccount, StrategyFacts.fresh, role: viewer),
      );
      final newer = text.replaceFirst('"viewer"', '"coach"');
      expect(
        (factsFromText(newer) as CloudRowRead<CloudFacts>).value.role,
        const RoleUnknown(),
      );
    });

    test('pictures read back as written, an empty page included', () {
      for (final stored in [
        StoredPictures('page-a', {
          'p1': picture('png'),
          'p2': const PictureAsset(
            provider: 'convex',
            uploadStatus: 'pending',
            fileExtension: 'webp',
          ),
        }),
        StoredPictures('page-b', const {}),
      ]) {
        final text = jsonEncode(picturesToJson(stored));
        expect(picturesFromText(text), isA<CloudRowRead<StoredPictures>>());
        expect(
          (picturesFromText(text) as CloudRowRead<StoredPictures>).value,
          stored,
        );
      }
    });
  });

  group('the role', () {
    test('is kept from the page list the strategy was taken up with, through '
        'a reopen', () async {
      final storage = MemoryStorage();
      var store = await adopted(storage);
      expect((await syncOf(store)).roleOf(testAccount), editor);
      store = await reopened(store, storage);
      expect((await syncOf(store)).roleOf(testAccount), editor);
      expect((await syncOf(store)).editsAs(testAccount), isTrue);
    });

    test('a second account on the same machine reads role unknown, and so '
        'cannot edit', () async {
      final storage = MemoryStorage();
      var store = await adopted(storage);
      store = await reopened(store, storage);
      final cloud = await syncOf(store);
      expect(cloud.roleOf(otherAccount), const RoleUnknown());
      expect(cloud.editsAs(otherAccount), isFalse);
      expect(
        await store.record(otherAccount, strategyId, [
          await arrivalIn(store, listAs(withImage(), editor)),
        ]),
        isA<Refused<Recorded, CommitRefusal>>(),
      );
      expect((await syncOf(store)).roleOf(otherAccount), const RoleUnknown());
    });

    test(
      'a page list saying viewer replaces editor, and that persists',
      () async {
        final storage = MemoryStorage();
        var store = await adopted(storage);
        await recordAll(store, [
          await arrivalIn(store, listAs(withImage(), viewer)),
        ]);
        store = await reopened(store, storage);
        final cloud = await syncOf(store);
        expect(cloud.roleOf(testAccount), viewer);
        expect(cloud.editsAs(testAccount), isFalse);
      },
    );

    test('an older page list the queue does not take leaves the role as it '
        'was', () async {
      final storage = MemoryStorage();
      final store = await adopted(storage);
      final session = await sessionOf(store);
      final older = tick();
      await recordAll(store, [
        await arrivalIn(store, listAs(withImage(), editor)),
      ]);
      final recorded = await recordAll(store, [
        arrivedAs(listAs(withImage(), viewer), session: session, asked: older),
      ]);
      expect(recorded.outcomes.single, isA<ReportNotApplicable>());
      expect((await syncOf(store)).roleOf(testAccount), editor);
    });

    test(
      'a page list for another strategy is refused, and stores no role',
      () async {
        final storage = MemoryStorage();
        final store = await adopted(storage);
        final elsewhere = strategyRows(pages: [page('page-a', sortIndex: 0)]);
        final other = HeaderRead(
          strategy: strategyRow(publicId: 'strategy-other'),
          pages: elsewhere.pages.toList(),
          settings: elsewhere.settings.toList(),
          role: viewer,
        );
        expect(
          await store.record(testAccount, strategyId, [
            await arrivalIn(store, other),
          ]),
          isA<Refused<Recorded, CommitRefusal>>(),
        );
        expect((await syncOf(store)).roleOf(testAccount), editor);
      },
    );

    test('lost edit access wins over a stored editor role', () async {
      final storage = MemoryStorage();
      var store = await adopted(storage);
      savedValue(
        await store.commitAs(
          testAccount,
          strategyId,
          movePatch('move'),
          seen: await seenIn(store),
        ),
      );
      final sent = await claimAll(store);
      await recordAll(store, [
        BatchRefused(
          sent.attempt,
          BatchRefusal.editAccessRemoved,
          point: tick(),
        ),
      ]);
      store = await reopened(store, storage);
      final cloud = await syncOf(store);
      expect(cloud.roleOf(testAccount), editor);
      expect(cloud.editsAs(testAccount), isFalse);
    });
  });

  group('the pictures', () {
    test(
      'are written in the same commit as the page result they came with',
      () async {
        final storage = MemoryStorage();
        final store0 = await adopted(storage);
        await store0.close();
        final (engine, counts) = counting(MemoryEngine(storage));
        final store = await openCloudStore(engine);
      await recordAll(store, [const AppRestarted(build: build)]);
        final server = withOp(
          withImage(),
          movePatch('server', elementId: 'e1'),
        );
        counts.reset();
        await recordAll(store, [
          await arrivalIn(
            store,
            pageWith(server, 'page-a', {'p1': picture('jpg')}),
          ),
        ]);
        expect(counts.commits, 1);
        expect(
          counts.written,
          containsAll([
            (area, assetsName('page-a')),
            (area, 'read/page/${digestOf('page-a')}'),
          ]),
        );
      },
    );

    test(
      'a page with no pictures stores an empty map, which reads as read',
      () async {
        final storage = MemoryStorage();
        var store = await adopted(storage);
        expect(storage.contents[area]![assetsName('page-b')], isNotNull);
        store = await reopened(store, storage);
        expect(picturesOn(await pageIn(store, 'page-b')), isEmpty);
      },
    );

    test('a page whose content was read before pictures were kept reads as '
        'not read', () async {
      final storage = MemoryStorage();
      var store = await adopted(storage);
      await store.close();
      final before = editable(storage.contents);
      before[area]!.remove(assetsName('page-a'));
      final cloud = jsonDecode(before[area]!['cloud']!) as Map<String, Object?>;
      cloud.remove('role');
      before[area]!['cloud'] = jsonEncode(cloud);
      store = await openCloudStore(MemoryEngine(MemoryStorage(before)));
      expect((await pageIn(store, 'page-a')).content, isA<ContentNotRead>());
      expect(picturesOn(await pageIn(store, 'page-b')), isEmpty);
      expect((await syncOf(store)).roleOf(testAccount), const RoleUnknown());
      expect((await syncOf(store)).editsAs(testAccount), isFalse);
    });

    test('a newer page result replaces them whole', () async {
      final storage = MemoryStorage();
      var store = await adopted(
        storage,
        pictures: {'p1': picture('png'), 'p2': picture('gif')},
      );
      await recordAll(store, [
        await arrivalIn(
          store,
          pageWith(withImage(), 'page-a', {'p1': picture('jpg')}),
        ),
      ]);
      store = await reopened(store, storage);
      expect(picturesOn(await pageIn(store, 'page-a')), {'p1': picture('jpg')});
    });

    test('a page result with the same pictures writes no pictures entry, and '
        'one changed picture writes only its page', () async {
      final storage = MemoryStorage();
      final store0 = await adopted(storage);
      await store0.close();
      final (engine, counts) = counting(MemoryEngine(storage));
      final store = await openCloudStore(engine);
      await recordAll(store, [const AppRestarted(build: build)]);
      final pictures = {'p1': picture('png')};
      final edited = withOp(withImage(), movePatch('teammate'));
      counts.reset();
      await recordAll(store, [
        await arrivalIn(store, pageWith(edited, 'page-a', pictures)),
      ]);
      expect(counts.commits, 1);
      expect(
        counts.written.where((written) => written.$2.startsWith('assets/')),
        isEmpty,
      );
      counts.reset();
      await recordAll(store, [
        await arrivalIn(
          store,
          pageWith(edited, 'page-a', {'p1': picture('png', status: 'failed')}),
        ),
      ]);
      expect(
        counts.written.where((written) => written.$2.startsWith('assets/')),
        [(area, assetsName('page-a'))],
      );
    });

    test('a page result the queue defers until the list shows its page '
        'stores no pictures', () async {
      final storage = MemoryStorage();
      final store = await adopted(storage);
      final added = withOp(withImage(), pageAdd('add', 'page-c'));
      final recorded = await recordAll(store, [
        await arrivalIn(
          store,
          pageWith(added, 'page-c', {'p9': picture('png')}),
        ),
      ]);
      expect(effectsOf(recorded), contains(const PageResultDeferred('page-c')));
      expect(
        storage.contents[area]!.containsKey(assetsName('page-c')),
        isFalse,
      );
    });

    test('are deleted with their page', () async {
      final storage = MemoryStorage();
      var store = await adopted(storage);
      final without = strategyRows(
        pages: [page('page-b', sortIndex: 0)],
        elements: [element('e3', pageId: 'page-b')],
      );
      await recordAll(store, [await arrivalIn(store, listAs(without, editor))]);
      expect(
        storage.contents[area]!.containsKey(assetsName('page-a')),
        isFalse,
      );
      expect(storage.contents[area]!.containsKey(assetsName('page-b')), isTrue);
      store = await reopened(store, storage);
      expect(
        await store.readPage(strategyId, 'page-a'),
        isA<NotFound<PageContent>>(),
      );
    });

    test(
      "an image's row stays byte for byte as stored after an edit to "
      'another element on its page, offline, with its picture unknown',
      () async {
        final storage = MemoryStorage();
        var store = await adopted(storage, pictures: const {});
        final name = elementName('page-a', 'i1');
        final before = storage.contents[area]![name];
        expect(before, isNotNull);
        store = await reopened(store, storage);
        expect(picturesOn(await pageIn(store, 'page-a')), isEmpty);
        savedValue(
          await store.commitAs(
            testAccount,
            strategyId,
            movePatch('move', elementId: 'e1'),
            seen: await seenIn(store),
          ),
        );
        store = await reopened(store, storage);
        expect(storage.contents[area]![name], before);
        final shown = elementOn(await pageIn(store, 'page-a'), 'i1');
        expect((shown as LiveElement).payload.data['assetId'], 'p1');
      },
    );
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_strategy_copy_box.dart';

import 'strategy_copy_fixtures.dart';

const _scope = StrategyCopyScope(
  deploymentUrl: 'https://one.convex.cloud',
  accountId: 'account-a',
);

final _t0 = DateTime.utc(2026, 10, 17, 12);
DateTime _at(int seconds) => _t0.add(Duration(seconds: seconds));

void main() {
  late MemoryCloudStrategyCopyStore store;

  setUp(() => store = MemoryCloudStrategyCopyStore());

  Future<void> keepPage(
    String pageId, {
    required int askedAt,
    int? arrivedAt,
    List<Map<String, Object?>> elements = const [],
    int revision = 1,
  }) =>
      store.writePage(
        _scope,
        'strategy',
        pageAnswer(pageId, elements: elements, revision: revision),
        askedAt: _at(askedAt),
        arrivedAt: _at(arrivedAt ?? askedAt),
      );

  test('a kept shell and page read back through the live decoders', () async {
    await store.writeShell(
      _scope,
      shellAnswer(['a', 'b']),
      askedAt: _at(0),
      arrivedAt: _at(0),
    );
    await keepPage('a', askedAt: 0, elements: [agentRow('agent', 'a')]);

    final shell = store.readShell(_scope, 'strategy')!;
    expect(shell.fromCopy, isTrue);
    expect(shell.serverAnswer, isNull);
    expect(shell.pages.map((page) => page.publicId), ['a', 'b']);
    final page = store.readPage(_scope, 'strategy', 'a')!;
    expect(page.fromCopy, isTrue);
    expect(page.elements.single.publicId, 'agent');
    expect(page.elements.single.decodedPayload()['id'], 'agent');
    expect(store.readPage(_scope, 'strategy', 'b'), isNull);
    expect(store.keepsStrategy(_scope, 'strategy'), isTrue);
  });

  test('an older answer never moves a row back', () async {
    await keepPage('a',
        askedAt: 0, elements: [agentRow('agent', 'a', revision: 3, x: 3)]);
    // An answer asked earlier, arriving late, holds revision 2.
    await keepPage('a', askedAt: 0, arrivedAt: 5, elements: [
      agentRow('agent', 'a', revision: 2, x: 2),
    ]);
    expect(
      store.readPage(_scope, 'strategy', 'a')!.elements.single.revision,
      3,
    );
  });

  test('a deletion stays as the tombstone the server sent', () async {
    await keepPage('a',
        askedAt: 0, elements: [agentRow('agent', 'a', revision: 1)]);
    await keepPage('a', askedAt: 1, elements: [
      agentRow('agent', 'a', revision: 2, deleted: true),
    ]);
    // A slower read from before the delete arrives after it.
    await keepPage('a', askedAt: 0, arrivedAt: 2, elements: [
      agentRow('agent', 'a', revision: 1),
    ]);
    final element = store.readPage(_scope, 'strategy', 'a')!.elements.single;
    expect(element.deleted, isTrue);
    expect(element.revision, 2);
  });

  test('a row missing from an answer asked before the last one arrived stays',
      () async {
    // A live answer at second 5 brings a new agent.
    await keepPage('a', askedAt: 5, elements: [
      agentRow('old', 'a'),
      agentRow('new', 'a'),
    ]);
    // A read asked at second 1 answers after it, without the new agent.
    await keepPage('a',
        askedAt: 1, arrivedAt: 6, elements: [agentRow('old', 'a')]);
    expect(
      store.readPage(_scope, 'strategy', 'a')!.elements.map((e) => e.publicId),
      unorderedEquals(['old', 'new']),
    );

    // A read asked after that brings the page without it: its tombstone
    // was purged.
    await keepPage('a', askedAt: 7, elements: [agentRow('old', 'a')]);
    expect(
      store.readPage(_scope, 'strategy', 'a')!.elements.map((e) => e.publicId),
      ['old'],
    );
  });

  test('a page with any row that does not decode is not kept at all', () async {
    await keepPage('a', askedAt: 0, elements: [
      agentRow('good', 'a'),
      agentRow('bad', 'a'),
    ]);
    final key = store.values.keys.singleWhere((key) => key.contains('page|'));
    final entry = jsonDecode(store.values[key]!) as Map<String, dynamic>;
    final rows = (entry['answer'] as Map)['elements'] as List;
    (rows.last as Map)['revision'] = 'not a number';
    store.values[key] = jsonEncode(entry);

    expect(store.readPage(_scope, 'strategy', 'a'), isNull);
  });

  test('an entry of another format version is read as absent', () async {
    await keepPage('a', askedAt: 0);
    final key = store.values.keys.single;
    final entry = jsonDecode(store.values[key]!) as Map<String, dynamic>;
    store.values[key] = jsonEncode({...entry, 'copyVersion': 2});
    expect(store.readPage(_scope, 'strategy', 'a'), isNull);
  });

  test('each deployment and account keeps its own copy', () async {
    const otherAccount = StrategyCopyScope(
      deploymentUrl: 'https://one.convex.cloud',
      accountId: 'account-b',
    );
    const otherDeployment = StrategyCopyScope(
      deploymentUrl: 'https://two.convex.cloud',
      accountId: 'account-a',
    );
    for (final scope in [_scope, otherAccount, otherDeployment]) {
      await store.writeShell(scope, shellAnswer(['a']),
          askedAt: _at(0), arrivedAt: _at(0));
    }

    await store.deleteAccount(_scope);

    expect(store.readShell(_scope, 'strategy'), isNull);
    expect(store.readShell(otherAccount, 'strategy'), isNotNull);
    expect(store.readShell(otherDeployment, 'strategy'), isNotNull);
  });

  test('a full snapshot keeps every page with the images it shows', () async {
    await store.writeFullSnapshot(
      _scope,
      fullAnswer(
        ['a', 'b', 'c'],
        elements: [
          agentRow('agent', 'a'),
          imageRow('image', 'b', 'picture'),
        ],
        lineups: [lineupRow('lineup', 'c', 'lineup-image')],
        assets: [assetRow('picture'), assetRow('lineup-image')],
      ),
      askedAt: _at(0),
      arrivedAt: _at(1),
    );

    expect(
      store.lastFullRefresh(_scope, 'strategy')!.isAtSameMomentAs(_at(1)),
      isTrue,
    );
    expect(
      store.readShell(_scope, 'strategy')!.pages.map((page) => page.publicId),
      ['a', 'b', 'c'],
    );
    expect(store.readPage(_scope, 'strategy', 'a')!.elements.single.publicId,
        'agent');
    expect(
        store.readPage(_scope, 'strategy', 'b')!.assetsById.keys, ['picture']);
    final c = store.readPage(_scope, 'strategy', 'c')!;
    expect(c.lineups.single.publicId, 'lineup');
    expect(c.assetsById.keys, ['lineup-image']);
  });

  test('a newer shell without a page drops that page; an older one does not',
      () async {
    await store.writeShell(_scope, shellAnswer(['a', 'b'], revision: 2),
        askedAt: _at(0), arrivedAt: _at(0));
    await keepPage('a', askedAt: 0);
    await keepPage('b', askedAt: 0);

    // From before page b was added.
    await store.writeShell(_scope, shellAnswer(['a'], revision: 1),
        askedAt: _at(1), arrivedAt: _at(1));
    expect(store.readShell(_scope, 'strategy')!.pages, hasLength(2));
    expect(store.readPage(_scope, 'strategy', 'b'), isNotNull);

    // Page b deleted.
    await store.writeShell(_scope, shellAnswer(['a'], revision: 3),
        askedAt: _at(2), arrivedAt: _at(2));
    expect(store.readShell(_scope, 'strategy')!.pages, hasLength(1));
    expect(store.readPage(_scope, 'strategy', 'b'), isNull);
    expect(store.readPage(_scope, 'strategy', 'a'), isNotNull);
  });
}

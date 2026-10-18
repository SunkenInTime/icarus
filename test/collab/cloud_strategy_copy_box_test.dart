import 'dart:convert';

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/collab/cloud_library_copy.dart';
import 'package:icarus/collab/cloud_strategy_copy_box.dart';

import 'strategy_copy_fixtures.dart';

const _deployment = 'https://one.convex.cloud';

/// The scope of [accountId] signing in now: a session of its own.
CloudCopyScope _beginSession(String accountId) =>
    CloudCopyScope.begin(deploymentUrl: _deployment, accountId: accountId);

late CloudCopyScope _scope;

final _t0 = DateTime.utc(2026, 10, 17, 12);
DateTime _at(int seconds) => _t0.add(Duration(seconds: seconds));

void main() {
  late MemoryCloudStrategyCopyStore store;

  setUp(() {
    store = MemoryCloudStrategyCopyStore();
    _scope = _beginSession('account-a');
  });

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

  test('a strategy whose only kept page is in another format is not kept',
      () async {
    await store.writeShell(_scope, shellAnswer(['a']),
        askedAt: _at(0), arrivedAt: _at(0));
    await keepPage('a', askedAt: 0);
    expect(store.keepsStrategy(_scope, 'strategy'), isTrue);

    final key = store.values.keys.singleWhere((key) => key.contains('page|'));
    final entry = jsonDecode(store.values[key]!) as Map<String, dynamic>;
    store.values[key] = jsonEncode({...entry, 'copyVersion': 2});
    expect(store.keepsStrategy(_scope, 'strategy'), isFalse);
  });

  test('a kept page says when the server last answered for it', () async {
    await keepPage('a', askedAt: 0, arrivedAt: 3);
    expect(
      store.readPage(_scope, 'strategy', 'a')!.copiedAt!.isAtSameMomentAs(
            _at(3),
          ),
      isTrue,
    );
  });

  for (final (name, open)
      in <(String, Future<CloudStrategyCopyStore> Function())>[
    ('memory', () async => MemoryCloudStrategyCopyStore()),
    ('Hive', _openHiveStore),
  ]) {
    group('on $name,', () {
      // The ways a session ends (see AuthProvider): Supabase signs the
      // account out, another account signs in, or the user signs out. Each
      // ends the account's sessions, then deletes what it kept.
      for (final (ending, nextAccount) in [
        ('Supabase signs it out', null),
        ('another account signs in', 'account-b'),
        ('the user signs out', null),
      ]) {
        test('an answer held while $ending keeps nothing for the old account',
            () async {
          final copy = await open();
          final asked = _beginSession('account-a');
          await copy.writeShell(asked, shellAnswer(['a']),
              askedAt: _at(0), arrivedAt: _at(0));

          asked.endSessions();
          final next = nextAccount == null ? null : _beginSession(nextAccount);
          await copy.deleteAllExcept(next);
          // The held answer arrives now.
          await copy.writeShell(asked, shellAnswer(['a', 'b']),
              askedAt: _at(1), arrivedAt: _at(2));
          await copy.writePage(asked, 'strategy', pageAnswer('a'),
              askedAt: _at(1), arrivedAt: _at(2));
          await copy.writeFullSnapshot(asked, fullAnswer(['a']),
              askedAt: _at(1), arrivedAt: _at(2));

          expect(copy.keptStrategyIds(asked), isEmpty);
          if (next != null) expect(copy.keptStrategyIds(next), isEmpty);

          // The same account signing back in writes as usual.
          final again = _beginSession('account-a');
          await copy.writeShell(again, shellAnswer(['a']),
              askedAt: _at(3), arrivedAt: _at(3));
          expect(copy.readShell(again, 'strategy'), isNotNull);
        });
      }
    });
  }

  test('each deployment and account keeps its own copy', () async {
    const otherAccount = CloudCopyScope(
      deploymentUrl: 'https://one.convex.cloud',
      accountId: 'account-b',
    );
    const otherDeployment = CloudCopyScope(
      deploymentUrl: 'https://two.convex.cloud',
      accountId: 'account-a',
    );
    for (final scope in [_scope, otherAccount, otherDeployment]) {
      await store.writeShell(scope, shellAnswer(['a']),
          askedAt: _at(0), arrivedAt: _at(0));
    }

    // Another account signed in: only its entries stay.
    await store.deleteAllExcept(otherAccount);
    expect(store.readShell(_scope, 'strategy'), isNull);
    expect(store.readShell(otherDeployment, 'strategy'), isNull);
    expect(store.readShell(otherAccount, 'strategy'), isNotNull);

    // Signed out: nothing stays.
    await store.deleteAllExcept(null);
    expect(store.entryKeys, isEmpty);
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
    // Its images aren't known to be on disk yet.
    expect(store.lastFullRefresh(_scope, 'strategy'), isNull);
    await store.noteFullRefresh(_scope, 'strategy', at: _at(1));
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

Future<CloudStrategyCopyStore> _openHiveStore() async {
  final dir = await Directory.systemTemp.createTemp('strategy-copy-');
  Hive.init(dir.path);
  final box = await Hive.openBox<String>(HiveBoxNames.cloudStrategyCopyBox);
  addTearDown(() async {
    await box.deleteFromDisk();
    await Hive.close();
    await dir.delete(recursive: true);
  });
  return HiveCloudStrategyCopyStore();
}
